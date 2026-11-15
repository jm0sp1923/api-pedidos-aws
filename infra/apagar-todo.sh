#!/usr/bin/env bash
#
# apagar-todo.sh
# Elimina TODO lo creado por los scripts de este proyecto.
# Orden: pipeline -> CodeBuild -> conexion -> servicios -> cluster ->
#        grupo de seguridad -> ECR -> tablas -> roles -> bucket -> logs.
#
set -uo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
CLUSTER="${CLUSTER:-cluster-pedidos}"
REPO="${REPO:-api-pedidos}"
PIPELINE="${PIPELINE:-pipeline-pedidos}"
PROYECTO_BUILD="${PROYECTO_BUILD:-construccion-pedidos}"
CONEXION="${CONEXION:-conexion-github-pedidos}"
GRUPO_SEG="${GRUPO_SEG:-pedidos-http}"
ROL_TAREA="rol-tarea-pedidos"
ROL_BUILD="rol-codebuild-pedidos"
ROL_PIPELINE="rol-codepipeline-pedidos"

titulo() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
ok()     { printf '    \033[0;32mOK\033[0m %s\n' "$1"; }
aviso()  { printf '    \033[0;33m--\033[0m %s\n' "$1"; }

read -r -p "Esto borrara el pipeline, los dos servicios, las tablas y el repositorio. Escriba BORRAR: " C
[ "$C" = "BORRAR" ] || { echo "Cancelado."; exit 0; }

ID_CUENTA="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="artefactos-pedidos-$ID_CUENTA-$REGION"

titulo "1/10 Pipeline"
aws codepipeline delete-pipeline --name "$PIPELINE" --region "$REGION" 2>/dev/null \
  && ok "Pipeline eliminado" || aviso "No existe"

titulo "2/10 Proyecto de CodeBuild"
aws codebuild delete-project --name "$PROYECTO_BUILD" --region "$REGION" 2>/dev/null \
  && ok "Proyecto eliminado" || aviso "No existe"
aws logs delete-log-group --log-group-name "/aws/codebuild/$PROYECTO_BUILD" --region "$REGION" 2>/dev/null

titulo "3/10 Conexion con GitHub"
ARN="$(aws codeconnections list-connections --region "$REGION" \
  --query "Connections[?ConnectionName=='$CONEXION'].ConnectionArn | [0]" --output text 2>/dev/null)"
if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
  aws codeconnections delete-connection --connection-arn "$ARN" --region "$REGION" && ok "Conexion eliminada"
  aviso "Revoque tambien AWS Connector for GitHub en github.com/settings/installations"
else
  aviso "No existe"
fi

titulo "4/10 Servicios de ECS"
for entorno in pruebas produccion; do
  SERV="servicio-pedidos-$entorno"
  if aws ecs describe-services --cluster "$CLUSTER" --services "$SERV" --region "$REGION" \
      --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
    aws ecs update-service --cluster "$CLUSTER" --service "$SERV" --desired-count 0 --region "$REGION" >/dev/null
    aws ecs delete-service --cluster "$CLUSTER" --service "$SERV" --force --region "$REGION" >/dev/null
    ok "Servicio $SERV eliminado"
  else
    aviso "El servicio $SERV no existe"
  fi
done
printf '    .. esperando a que se liberen las interfaces de red'
for _ in $(seq 1 20); do
  P="$(aws ecs list-tasks --cluster "$CLUSTER" --region "$REGION" --query 'length(taskArns)' --output text 2>/dev/null || echo 0)"
  [ "$P" = "0" ] && break; printf '.'; sleep 6
done; printf '\n'

titulo "5/10 Definiciones de tarea"
for entorno in pruebas produccion; do
  for arn in $(aws ecs list-task-definitions --family-prefix "tarea-pedidos-$entorno" --status ACTIVE \
      --region "$REGION" --query 'taskDefinitionArns[]' --output text 2>/dev/null); do
    aws ecs deregister-task-definition --task-definition "$arn" --region "$REGION" >/dev/null
  done
  ok "Revisiones de tarea-pedidos-$entorno dadas de baja"
done

titulo "6/10 Cluster"
aws ecs delete-cluster --cluster "$CLUSTER" --region "$REGION" >/dev/null 2>&1 \
  && ok "Cluster eliminado" || aviso "No se pudo eliminar"

titulo "7/10 Grupo de seguridad"
VPC="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
SG="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters Name=group-name,Values="$GRUPO_SEG" Name=vpc-id,Values="$VPC" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ -n "$SG" ] && [ "$SG" != "None" ]; then
  for i in 1 2 3 4 5; do
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null && { ok "Grupo $SG eliminado"; break; }
    [ "$i" = "5" ] && aviso "Siga en uso; borrelo a mano en unos minutos"
    printf '    .. reintentando (%s)\n' "$i"; sleep 15
  done
else
  aviso "No existe"
fi

titulo "8/10 Repositorio de ECR y tablas"
aws ecr delete-repository --repository-name "$REPO" --force --region "$REGION" >/dev/null 2>&1 \
  && ok "Repositorio $REPO eliminado" || aviso "No existe"
for entorno in pruebas produccion; do
  aws dynamodb delete-table --table-name "pedidos-$entorno" --region "$REGION" >/dev/null 2>&1 \
    && ok "Tabla pedidos-$entorno eliminada" || aviso "La tabla pedidos-$entorno no existe"
done

titulo "9/10 Roles"
for par in "$ROL_TAREA:politica-acceso-pedidos" "$ROL_BUILD:politica-construccion" "$ROL_PIPELINE:politica-orquestacion"; do
  rol="${par%%:*}"; pol="${par##*:}"
  if aws iam get-role --role-name "$rol" >/dev/null 2>&1; then
    aws iam delete-role-policy --role-name "$rol" --policy-name "$pol" 2>/dev/null
    aws iam delete-role --role-name "$rol" && ok "Rol $rol eliminado"
  else
    aviso "El rol $rol no existe"
  fi
done
aviso "ecsTaskExecutionRole se conserva: es estandar y no genera costo"

titulo "10/10 Artefactos y registros"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  for tipo in Versions DeleteMarkers; do
    while true; do
      LOTE="$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 500 \
        --query "{Objects: ${tipo}[].{Key:Key,VersionId:VersionId}}" --output json)"
      N="$(echo "$LOTE" | jq -r '.Objects | if . == null then 0 else length end')"
      [ "$N" -eq 0 ] && break
      echo "$LOTE" | jq -c '{Objects: .Objects, Quiet: true}' > /tmp/borrar-lote.json
      aws s3api delete-objects --bucket "$BUCKET" --delete "file:///tmp/borrar-lote.json" >/dev/null
      ok "$N entradas de tipo $tipo eliminadas"
    done
  done
  rm -f /tmp/borrar-lote.json
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" && ok "Bucket eliminado"
else
  aviso "El bucket $BUCKET no existe"
fi
for entorno in pruebas produccion; do
  aws logs delete-log-group --log-group-name "/ecs/pedidos-$entorno" --region "$REGION" 2>/dev/null
done
ok "Grupos de registro eliminados"

printf '\n\033[1;32mLimpieza completada.\033[0m\n\n'
