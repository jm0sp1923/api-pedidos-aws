# =============================================================================
# Dockerfile multietapa para la API de gestion de pedidos
#
# Etapa 1: instala todas las dependencias y transpila TypeScript.
# Etapa 2: parte de una imagen limpia y copia solo lo necesario para correr.
# La imagen final no lleva TypeScript, ni ts-node, ni codigo fuente.
# =============================================================================

FROM node:20-alpine AS compilacion
WORKDIR /app
# Los manifiestos se copian primero: si no cambian, Docker reutiliza la capa
# de npm ci y la reconstruccion tarda segundos en vez de minutos.
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
COPY pruebas ./pruebas
RUN npm run compilar

FROM node:20-alpine AS ejecucion
# tini reenvia las senales del sistema al proceso de Node. Sin el, el
# SIGTERM que envia ECS al detener la tarea no llega y el contenedor muere
# de forma abrupta tras el tiempo de espera.
RUN apk add --no-cache tini

ENV NODE_ENV=production
ENV PORT=3000

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=compilacion /app/dist/src ./dist/src

# La imagen base trae el usuario 'node' sin privilegios.
USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/src/servidor.js"]
