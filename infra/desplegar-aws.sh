#!/usr/bin/env bash
#
# desplegar-aws.sh
# Aprovisiona la plataforma de pedidos en AWS: repositorio de imagenes,
# tablas de DynamoDB, cluster de ECS y DOS servicios de Fargate, uno por
# entorno (pruebas y produccion).
#
# Requisitos: AWS CLI v2, Docker en ejecucion y jq.
# Uso:  bash infra/desplegar-aws.sh
#
set -euo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
REPO="${REPO:-api-pedidos}"
ETIQUETA="${ETIQUETA:-inicial}"
CLUSTER="${CLUSTER:-cluster-pedidos}"
GRUPO_SEG="${GRUPO_SEG:-pedidos-http}"
ROL_EJECUCION="ecsTaskExecutionRole"
ROL_TAREA="rol-tarea-pedidos"
PUERTO=3000
ENTORNOS=("pruebas" "produccion")

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLITICAS="$RAIZ/infra/politicas"
GENERADO="$RAIZ/infra/.generado"
mkdir -p "$GENERADO"

titulo() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
ok()     { printf '    \033[0;32mOK\033[0m %s\n' "$1"; }
aviso()  { printf '    \033[0;33m--\033[0m %s\n' "$1"; }

command -v aws    >/dev/null || { echo "Falta AWS CLI v2"; exit 1; }
command -v docker >/dev/null || { echo "Falta Docker"; exit 1; }
command -v jq     >/dev/null || { echo "Falta jq (brew install jq)"; exit 1; }
docker info >/dev/null 2>&1  || { echo "Docker no esta en ejecucion."; exit 1; }

# ---------------------------------------------------------------------------
titulo "0/8 Identificando la cuenta"
ID_CUENTA="$(aws sts get-caller-identity --query Account --output text)"
REGISTRO="$ID_CUENTA.dkr.ecr.$REGION.amazonaws.com"
IMAGEN="$REGISTRO/$REPO:$ETIQUETA"
ok "Cuenta $ID_CUENTA - region $REGION"

render() {
  sed -e "s|ID_CUENTA|$ID_CUENTA|g" -e "s|REGION|$REGION|g" "$POLITICAS/$1" > "$GENERADO/$1"
  echo "$GENERADO/$1"
}

# ---------------------------------------------------------------------------
titulo "1/8 Tablas de DynamoDB"
for entorno in "${ENTORNOS[@]}"; do
  TABLA="pedidos-$entorno"
  if aws dynamodb describe-table --table-name "$TABLA" --region "$REGION" >/dev/null 2>&1; then
    ok "La tabla $TABLA ya existe"
  else
    aws dynamodb create-table --table-name "$TABLA" --region "$REGION" \
      --attribute-definitions AttributeName=id,AttributeType=S \
      --key-schema AttributeName=id,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST >/dev/null
    ok "Tabla $TABLA creada (facturacion por solicitud)"
  fi
done
for entorno in "${ENTORNOS[@]}"; do
  aws dynamodb wait table-exists --table-name "pedidos-$entorno" --region "$REGION"
done
ok "Las dos tablas estan activas"

# ---------------------------------------------------------------------------
titulo "2/8 Repositorio de ECR"
if aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" >/dev/null 2>&1; then
  ok "El repositorio $REPO ya existe"
else
  aws ecr create-repository --repository-name "$REPO" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true >/dev/null
  ok "Repositorio $REPO creado con analisis de vulnerabilidades"
fi

# ---------------------------------------------------------------------------
titulo "3/8 Imagen inicial"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRO" >/dev/null
ok "Sesion iniciada en ECR"
docker build --platform linux/amd64 --provenance=false -t "$REPO:$ETIQUETA" "$RAIZ"
docker tag "$REPO:$ETIQUETA" "$IMAGEN"
docker push "$IMAGEN" >/dev/null
ok "Imagen publicada: $IMAGEN"

# ---------------------------------------------------------------------------
titulo "4/8 Roles de IAM"
cat > "$GENERADO/confianza-ecs.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "ecs-tasks.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
EOF

if aws iam get-role --role-name "$ROL_EJECUCION" >/dev/null 2>&1; then
  ok "El rol $ROL_EJECUCION ya existe"
else
  aws iam create-role --role-name "$ROL_EJECUCION" \
    --assume-role-policy-document "file://$GENERADO/confianza-ecs.json" >/dev/null
  aws iam attach-role-policy --role-name "$ROL_EJECUCION" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  ok "Rol $ROL_EJECUCION creado"
  sleep 10
fi

# El rol de TAREA es distinto del de ejecucion: este lo usa la aplicacion
# para hablar con DynamoDB, mientras que el de ejecucion solo sirve para
# descargar la imagen y escribir logs.
if aws iam get-role --role-name "$ROL_TAREA" >/dev/null 2>&1; then
  ok "El rol $ROL_TAREA ya existe"
else
  aws iam create-role --role-name "$ROL_TAREA" \
    --assume-role-policy-document "file://$GENERADO/confianza-ecs.json" \
    --description "Rol que usa la aplicacion para acceder a las tablas de pedidos" >/dev/null
  ok "Rol $ROL_TAREA creado"
  sleep 10
fi
aws iam put-role-policy --role-name "$ROL_TAREA" \
  --policy-name "politica-acceso-pedidos" \
  --policy-document "file://$(render politica-tarea-dynamodb.json)"
ok "Permisos de DynamoDB acotados a las dos tablas"

ARN_EJECUCION="arn:aws:iam::$ID_CUENTA:role/$ROL_EJECUCION"
ARN_TAREA="arn:aws:iam::$ID_CUENTA:role/$ROL_TAREA"

# ---------------------------------------------------------------------------
titulo "5/8 Cluster de ECS"
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>&1 \
  && { ok "Rol vinculado al servicio de ECS creado"; sleep 15; } \
  || ok "El rol vinculado al servicio de ECS ya existe"

if aws ecs describe-clusters --clusters "$CLUSTER" --region "$REGION" \
    --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
  ok "El cluster $CLUSTER ya existe"
else
  aws ecs create-cluster --cluster-name "$CLUSTER" --region "$REGION" \
    --capacity-providers FARGATE >/dev/null
  ok "Cluster $CLUSTER creado"
fi

# ---------------------------------------------------------------------------
titulo "6/8 Red y grupo de seguridad"
VPC="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"
SUBREDES="$(aws ec2 describe-subnets --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')"
ok "VPC $VPC"

ID_SG="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters Name=group-name,Values="$GRUPO_SEG" Name=vpc-id,Values="$VPC" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"
if [ "$ID_SG" = "None" ] || [ -z "$ID_SG" ]; then
  ID_SG="$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$GRUPO_SEG" --vpc-id "$VPC" \
    --description "Acceso HTTP al puerto $PUERTO de la API de pedidos" \
    --query 'GroupId' --output text)"
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$ID_SG" --protocol tcp --port "$PUERTO" --cidr 0.0.0.0/0 >/dev/null
  ok "Grupo de seguridad $ID_SG creado (entrada tcp/$PUERTO)"
else
  ok "El grupo de seguridad $ID_SG ya existe"
fi

# ---------------------------------------------------------------------------
titulo "7/8 Definiciones de tarea y servicios"
RED="awsvpcConfiguration={subnets=[$SUBREDES],securityGroups=[$ID_SG],assignPublicIp=ENABLED}"

for entorno in "${ENTORNOS[@]}"; do
  FAMILIA="tarea-pedidos-$entorno"
  SERVICIO="servicio-pedidos-$entorno"
  GRUPO_LOGS="/ecs/pedidos-$entorno"

  aws logs create-log-group --log-group-name "$GRUPO_LOGS" --region "$REGION" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$GRUPO_LOGS" --retention-in-days 7 --region "$REGION"

  jq -n --arg familia "$FAMILIA" --arg ejec "$ARN_EJECUCION" --arg tarea "$ARN_TAREA" \
        --arg imagen "$IMAGEN" --arg grupo "$GRUPO_LOGS" --arg region "$REGION" \
        --arg entorno "$entorno" --arg tabla "pedidos-$entorno" --argjson puerto "$PUERTO" '
  {
    family: $familia,
    networkMode: "awsvpc",
    requiresCompatibilities: ["FARGATE"],
    cpu: "256", memory: "512",
    executionRoleArn: $ejec,
    taskRoleArn: $tarea,
    runtimePlatform: { cpuArchitecture: "X86_64", operatingSystemFamily: "LINUX" },
    containerDefinitions: [{
      name: "api-pedidos",
      image: $imagen,
      essential: true,
      portMappings: [ { containerPort: $puerto, protocol: "tcp" } ],
      environment: [
        { name: "PORT", value: ($puerto|tostring) },
        { name: "ENTORNO", value: $entorno },
        { name: "PEDIDOS_TABLA", value: $tabla },
        { name: "AWS_REGION", value: $region }
      ],
      healthCheck: {
        command: ["CMD-SHELL", "node -e \"fetch(\u0027http://127.0.0.1:3000/health\u0027).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""],
        interval: 30, timeout: 5, retries: 3, startPeriod: 15
      },
      logConfiguration: {
        logDriver: "awslogs",
        options: { "awslogs-group": $grupo, "awslogs-region": $region, "awslogs-stream-prefix": "api" }
      }
    }]
  }' > "$GENERADO/tarea-$entorno.json"

  REVISION="$(aws ecs register-task-definition --region "$REGION" \
    --cli-input-json "file://$GENERADO/tarea-$entorno.json" \
    --query 'taskDefinition.revision' --output text)"
  ok "Definicion $FAMILIA:$REVISION registrada (tabla pedidos-$entorno)"

  if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICIO" --region "$REGION" \
      --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICIO" --region "$REGION" \
      --task-definition "$FAMILIA:$REVISION" --desired-count 1 --force-new-deployment >/dev/null
    ok "Servicio $SERVICIO actualizado"
  else
    aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICIO" --region "$REGION" \
      --task-definition "$FAMILIA:$REVISION" --desired-count 1 --launch-type FARGATE \
      --network-configuration "$RED" >/dev/null
    ok "Servicio $SERVICIO creado"
  fi
done

# ---------------------------------------------------------------------------
titulo "8/8 Direcciones publicas"
obtener_ip() {
  local servicio="$1" tarea eni
  for _ in $(seq 1 40); do
    tarea="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$servicio" \
      --desired-status RUNNING --region "$REGION" --query 'taskArns[0]' --output text 2>/dev/null)"
    [ "$tarea" != "None" ] && [ -n "$tarea" ] && break
    sleep 6
  done
  [ "$tarea" = "None" ] && { echo "sin-ip"; return; }
  eni="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$tarea" --region "$REGION" \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text)"
  aws ec2 describe-network-interfaces --network-interface-ids "$eni" --region "$REGION" \
    --query 'NetworkInterfaces[0].Association.PublicIp' --output text
}

IP_PRUEBAS="$(obtener_ip servicio-pedidos-pruebas)"
IP_PRODUCCION="$(obtener_ip servicio-pedidos-produccion)"
ok "pruebas    -> $IP_PRUEBAS"
ok "produccion -> $IP_PRODUCCION"

cat > "$RAIZ/.env.local" <<EOF
REGION=$REGION
ID_CUENTA=$ID_CUENTA
URL_PRUEBAS=http://$IP_PRUEBAS:$PUERTO
URL_PRODUCCION=http://$IP_PRODUCCION:$PUERTO
EOF

titulo "Despliegue completado"
cat <<EOF

  Cuenta ............. $ID_CUENTA
  Cluster ............ $CLUSTER
  Imagen ............. $IMAGEN
  Tablas ............. pedidos-pruebas / pedidos-produccion

  PRUEBAS    ......... http://$IP_PRUEBAS:$PUERTO
  PRODUCCION ......... http://$IP_PRODUCCION:$PUERTO

  Compruebe los dos entornos con:
    curl -s http://$IP_PRUEBAS:$PUERTO/health | jq
    curl -s http://$IP_PRODUCCION:$PUERTO/health | jq
    npm run probar-api -- http://$IP_PRUEBAS:$PUERTO

  Siguiente paso: bash infra/crear-pipeline.sh

EOF
