#!/usr/bin/env bash
#
# crear-pipeline.sh
# Crea el pipeline de CI/CD con cinco etapas:
#
#   Fuente -> Construccion -> DesplieguePruebas -> Aprobacion -> DespliegueProduccion
#
# PRERREQUISITO: los dos servicios de ECS deben existir.
#                Ejecute antes: bash infra/desplegar-aws.sh
#
# Uso:  USUARIO_GITHUB=tu-usuario REPO_GITHUB=tu-repo bash infra/crear-pipeline.sh
#
set -euo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
CLUSTER="${CLUSTER:-cluster-pedidos}"
PIPELINE="${PIPELINE:-pipeline-pedidos}"
PROYECTO_BUILD="${PROYECTO_BUILD:-construccion-pedidos}"
CONEXION="${CONEXION:-conexion-github-pedidos}"
ROL_BUILD="rol-codebuild-pedidos"
ROL_PIPELINE="rol-codepipeline-pedidos"
RAMA="${RAMA:-main}"

USUARIO_GITHUB="${USUARIO_GITHUB:-}"
REPO_GITHUB="${REPO_GITHUB:-api-pedidos}"

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLITICAS="$RAIZ/infra/politicas"
GENERADO="$RAIZ/infra/.generado"
mkdir -p "$GENERADO"

titulo() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
ok()     { printf '    \033[0;32mOK\033[0m %s\n' "$1"; }

command -v aws >/dev/null || { echo "Falta AWS CLI v2"; exit 1; }
command -v jq  >/dev/null || { echo "Falta jq"; exit 1; }
[ -n "$USUARIO_GITHUB" ] || { echo "Defina USUARIO_GITHUB"; exit 1; }

# ---------------------------------------------------------------------------
titulo "0/7 Comprobaciones previas"
ID_CUENTA="$(aws sts get-caller-identity --query Account --output text)"
ok "Cuenta $ID_CUENTA - region $REGION"

for entorno in pruebas produccion; do
  estado="$(aws ecs describe-services --cluster "$CLUSTER" --services "servicio-pedidos-$entorno" \
    --region "$REGION" --query 'services[0].status' --output text 2>/dev/null || echo "None")"
  [ "$estado" = "ACTIVE" ] || { echo "    Falta el servicio servicio-pedidos-$entorno. Ejecute antes: bash infra/desplegar-aws.sh"; exit 1; }
done
ok "Los dos servicios de ECS estan activos"

BUCKET_ARTEFACTOS="artefactos-pedidos-$ID_CUENTA-$REGION"

render() {
  sed -e "s|ID_CUENTA|$ID_CUENTA|g" -e "s|REGION|$REGION|g" \
      -e "s|BUCKET_ARTEFACTOS|$BUCKET_ARTEFACTOS|g" \
      -e "s|ARN_CONEXION|${ARN_CONEXION:-*}|g" \
      "$POLITICAS/$1" > "$GENERADO/$1"
  echo "$GENERADO/$1"
}

# ---------------------------------------------------------------------------
titulo "1/7 Bucket de artefactos"
if aws s3api head-bucket --bucket "$BUCKET_ARTEFACTOS" >/dev/null 2>&1; then
  ok "El bucket $BUCKET_ARTEFACTOS ya existe"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_ARTEFACTOS" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET_ARTEFACTOS" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  ok "Bucket $BUCKET_ARTEFACTOS creado"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET_ARTEFACTOS" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET_ARTEFACTOS" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
ok "Versionado activo y acceso publico bloqueado"

# ---------------------------------------------------------------------------
titulo "2/7 Conexion con GitHub"
ARN_CONEXION="$(aws codeconnections list-connections --region "$REGION" \
  --query "Connections[?ConnectionName=='$CONEXION'].ConnectionArn | [0]" --output text 2>/dev/null || echo "None")"
if [ "$ARN_CONEXION" = "None" ] || [ -z "$ARN_CONEXION" ]; then
  ARN_CONEXION="$(aws codeconnections create-connection --region "$REGION" \
    --provider-type GitHub --connection-name "$CONEXION" --query 'ConnectionArn' --output text)"
  ok "Conexion creada: $ARN_CONEXION"
else
  ok "La conexion ya existe: $ARN_CONEXION"
fi

ESTADO_CONEXION="$(aws codeconnections get-connection --connection-arn "$ARN_CONEXION" \
  --region "$REGION" --query 'Connection.ConnectionStatus' --output text)"
if [ "$ESTADO_CONEXION" != "AVAILABLE" ]; then
  cat <<EOF

    ACCION MANUAL REQUERIDA

    La conexion esta en estado $ESTADO_CONEXION. La autorizacion OAuth con
    GitHub no se puede hacer desde la CLI.

    1. Consola de AWS -> CodePipeline -> Configuracion -> Conexiones
    2. Seleccione '$CONEXION' y pulse 'Actualizar conexion pendiente'
    3. Autorice AWS Connector for GitHub y elija el repositorio
       $USUARIO_GITHUB/$REPO_GITHUB
    4. IMPORTANTE: el repositorio debe estar en su estado definitivo
       (publico o privado) ANTES de autorizar. Cambiarlo despues rompe
       el webhook y el disparo automatico deja de funcionar.
    5. Vuelva a ejecutar este script

EOF
  exit 1
fi
ok "Conexion en estado AVAILABLE"

# ---------------------------------------------------------------------------
titulo "3/7 Rol de CodeBuild"
if ! aws iam get-role --role-name "$ROL_BUILD" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROL_BUILD" \
    --assume-role-policy-document "file://$(render confianza-codebuild.json)" \
    --description "Rol que CodeBuild asume para probar, construir y publicar" >/dev/null
  ok "Rol $ROL_BUILD creado"; sleep 10
else
  ok "El rol $ROL_BUILD ya existe"
fi
aws iam put-role-policy --role-name "$ROL_BUILD" --policy-name "politica-construccion" \
  --policy-document "file://$(render politica-codebuild.json)"
ok "Politica de menor privilegio adjunta"

# ---------------------------------------------------------------------------
titulo "4/7 Proyecto de CodeBuild"
# privilegedMode permite ejecutar docker build dentro del contenedor.
# La cache de tipo S3 conserva node_modules entre compilaciones.
jq -n --arg nombre "$PROYECTO_BUILD" \
      --arg rol "arn:aws:iam::$ID_CUENTA:role/$ROL_BUILD" \
      --arg cache "$BUCKET_ARTEFACTOS/cache-codebuild" '
{
  name: $nombre,
  description: "Ejecuta las pruebas unitarias, construye la imagen y la publica en ECR",
  source: { type: "CODEPIPELINE", buildspec: "buildspec.yml" },
  artifacts: { type: "CODEPIPELINE" },
  environment: {
    type: "LINUX_CONTAINER",
    image: "aws/codebuild/amazonlinux2-x86_64-standard:5.0",
    computeType: "BUILD_GENERAL1_SMALL",
    privilegedMode: true
  },
  cache: { type: "S3", location: $cache },
  serviceRole: $rol,
  timeoutInMinutes: 25
}' > "$GENERADO/proyecto-build.json"

if aws codebuild batch-get-projects --names "$PROYECTO_BUILD" --region "$REGION" \
    --query 'projects[0].name' --output text 2>/dev/null | grep -q "$PROYECTO_BUILD"; then
  aws codebuild update-project --region "$REGION" \
    --cli-input-json "file://$GENERADO/proyecto-build.json" >/dev/null
  ok "Proyecto $PROYECTO_BUILD actualizado"
else
  aws codebuild create-project --region "$REGION" \
    --cli-input-json "file://$GENERADO/proyecto-build.json" >/dev/null
  ok "Proyecto $PROYECTO_BUILD creado (modo privilegiado y cache en S3)"
fi

# ---------------------------------------------------------------------------
titulo "5/7 Rol de CodePipeline"
if ! aws iam get-role --role-name "$ROL_PIPELINE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROL_PIPELINE" \
    --assume-role-policy-document "file://$(render confianza-codepipeline.json)" \
    --description "Rol que CodePipeline asume para orquestar las etapas" >/dev/null
  ok "Rol $ROL_PIPELINE creado"; sleep 10
else
  ok "El rol $ROL_PIPELINE ya existe"
fi
aws iam put-role-policy --role-name "$ROL_PIPELINE" --policy-name "politica-orquestacion" \
  --policy-document "file://$(render politica-codepipeline.json)"
ok "Politica de menor privilegio adjunta"

# ---------------------------------------------------------------------------
titulo "6/7 Definicion del pipeline"
jq -n \
  --arg pipeline "$PIPELINE" \
  --arg rol "arn:aws:iam::$ID_CUENTA:role/$ROL_PIPELINE" \
  --arg bucket "$BUCKET_ARTEFACTOS" \
  --arg conexion "$ARN_CONEXION" \
  --arg repo "$USUARIO_GITHUB/$REPO_GITHUB" \
  --arg rama "$RAMA" \
  --arg proyecto "$PROYECTO_BUILD" \
  --arg cluster "$CLUSTER" '
{
  pipeline: {
    name: $pipeline,
    roleArn: $rol,
    pipelineType: "V2",
    artifactStore: { type: "S3", location: $bucket },
    triggers: [{
      providerType: "CodeStarSourceConnection",
      gitConfiguration: {
        sourceActionName: "DescargarDesdeGitHub",
        push: [ { branches: { includes: [$rama] } } ]
      }
    }],
    stages: [
      {
        name: "Fuente",
        actions: [{
          name: "DescargarDesdeGitHub",
          actionTypeId: { category: "Source", owner: "AWS", provider: "CodeStarSourceConnection", version: "1" },
          configuration: { ConnectionArn: $conexion, FullRepositoryId: $repo, BranchName: $rama, DetectChanges: "true" },
          outputArtifacts: [{ name: "CodigoFuente" }],
          runOrder: 1
        }]
      },
      {
        name: "Construccion",
        actions: [{
          name: "PruebasYPublicacionDeImagen",
          actionTypeId: { category: "Build", owner: "AWS", provider: "CodeBuild", version: "1" },
          configuration: { ProjectName: $proyecto },
          inputArtifacts: [{ name: "CodigoFuente" }],
          outputArtifacts: [{ name: "DefinicionImagen" }],
          runOrder: 1
        }]
      },
      {
        name: "DespliegueAPruebas",
        actions: [{
          name: "ActualizarServicioPruebas",
          actionTypeId: { category: "Deploy", owner: "AWS", provider: "ECS", version: "1" },
          configuration: {
            ClusterName: $cluster,
            ServiceName: "servicio-pedidos-pruebas",
            FileName: "imagedefinitions.json",
            DeploymentTimeout: "10"
          },
          inputArtifacts: [{ name: "DefinicionImagen" }],
          runOrder: 1
        }]
      },
      {
        name: "AprobacionManual",
        actions: [{
          name: "ValidarEnPruebasAntesDeProduccion",
          actionTypeId: { category: "Approval", owner: "AWS", provider: "Manual", version: "1" },
          configuration: {
            CustomData: "Verifique la API en el entorno de pruebas antes de promover a produccion."
          },
          runOrder: 1
        }]
      },
      {
        name: "DespliegueAProduccion",
        actions: [{
          name: "ActualizarServicioProduccion",
          actionTypeId: { category: "Deploy", owner: "AWS", provider: "ECS", version: "1" },
          configuration: {
            ClusterName: $cluster,
            ServiceName: "servicio-pedidos-produccion",
            FileName: "imagedefinitions-produccion.json",
            DeploymentTimeout: "10"
          },
          inputArtifacts: [{ name: "DefinicionImagen" }],
          runOrder: 1
        }]
      }
    ]
  }
}' > "$GENERADO/pipeline.json"

if aws codepipeline get-pipeline --name "$PIPELINE" --region "$REGION" >/dev/null 2>&1; then
  aws codepipeline update-pipeline --region "$REGION" \
    --cli-input-json "file://$GENERADO/pipeline.json" >/dev/null
  ok "Pipeline $PIPELINE actualizado"
else
  aws codepipeline create-pipeline --region "$REGION" \
    --cli-input-json "file://$GENERADO/pipeline.json" >/dev/null
  ok "Pipeline $PIPELINE creado con cinco etapas"
fi

# ---------------------------------------------------------------------------
titulo "7/7 Resumen"
cat <<EOF

  Cuenta ............ $ID_CUENTA
  Repositorio ....... $USUARIO_GITHUB/$REPO_GITHUB (rama $RAMA)
  Pipeline .......... $PIPELINE

  Etapas:
    1. Fuente                GitHub via CodeConnections
    2. Construccion          pruebas unitarias + imagen en ECR
    3. DespliegueAPruebas    servicio-pedidos-pruebas
    4. AprobacionManual      requiere intervencion humana
    5. DespliegueAProduccion servicio-pedidos-produccion

  NO se lanza ninguna ejecucion automatica: haga un commit y un push para
  comprobar que el disparo por webhook funciona de verdad.

  Siga el estado con:
    aws codepipeline get-pipeline-state --name $PIPELINE --region $REGION \\
      --query 'stageStates[].{Etapa:stageName,Estado:latestExecution.status}' --output table

EOF
