/**
 * Pruebas funcionales contra un entorno desplegado.
 *
 * A diferencia de las pruebas unitarias, estas si necesitan la API corriendo
 * y DynamoDB detras. Sirven para validar el entorno de pruebas antes de
 * aprobar la promocion a produccion.
 *
 * Uso:  npm run probar-api -- http://<ip>:3000
 */
const BASE = (process.argv[2] ?? process.env.URL_API ?? "http://localhost:3000").replace(/\/+$/, "");

let superadas = 0;
let total = 0;

function registrar(nombre: string, paso: boolean, detalle: string): void {
  total += 1;
  if (paso) superadas += 1;
  console.log(`\n[${paso ? "PASA" : "FALLA"}] ${nombre}`);
  console.log(`   ${detalle}`);
}

const PEDIDO = {
  cliente: "Camila Rodriguez",
  correoCliente: `camila.${Date.now()}@lasalle.edu.co`,
  direccionEnvio: "Carrera 5 #59A-44, Bogota",
  items: [
    { producto: "Teclado mecanico", cantidad: 2, precioUnitario: 180000 },
    { producto: "Mouse inalambrico", cantidad: 1, precioUnitario: 95000 },
  ],
};

async function main(): Promise<void> {
  console.log("=".repeat(72));
  console.log("PRUEBAS FUNCIONALES - Plataforma de gestion de pedidos");
  console.log(`URL base: ${BASE}`);
  console.log("=".repeat(72));

  // 1. Salud y entorno
  const salud = await fetch(`${BASE}/health`);
  const cuerpoSalud = await salud.json();
  registrar(
    "GET /health responde 200",
    salud.status === 200 && cuerpoSalud.estado === "ok",
    `entorno: ${cuerpoSalud.entorno} - tabla: ${cuerpoSalud.tabla} - version: ${cuerpoSalud.version}`
  );

  // 2. Crear
  const creacion = await fetch(`${BASE}/pedidos`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(PEDIDO),
  });
  const creado = await creacion.json();
  registrar(
    "POST /pedidos crea el pedido y calcula el total",
    creacion.status === 201 && creado.total === 455000 && creado.estado === "PENDIENTE",
    `HTTP ${creacion.status} - id: ${creado.id} - total: ${creado.total}`
  );

  // 3. Leer por id
  const porId = await fetch(`${BASE}/pedidos/${creado.id}`);
  const cuerpoPorId = await porId.json();
  registrar(
    "GET /pedidos/{id} recupera el pedido desde DynamoDB",
    porId.status === 200 && cuerpoPorId.id === creado.id,
    `HTTP ${porId.status} - ${cuerpoPorId.cliente} - ${cuerpoPorId.items?.length} productos`
  );

  // 4. Avanzar estado
  const avance = await fetch(`${BASE}/pedidos/${creado.id}/estado`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ estado: "EN_PROCESO" }),
  });
  const avanzado = await avance.json();
  registrar(
    "PATCH /pedidos/{id}/estado avanza a EN_PROCESO",
    avance.status === 200 && avanzado.estado === "EN_PROCESO",
    `HTTP ${avance.status} - estado: ${avanzado.estado}`
  );

  // 5. Transicion invalida
  const invalida = await fetch(`${BASE}/pedidos/${creado.id}/estado`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ estado: "PENDIENTE" }),
  });
  const cuerpoInvalida = await invalida.json();
  registrar(
    "Una transicion hacia atras devuelve 409",
    invalida.status === 409,
    `HTTP ${invalida.status} - ${cuerpoInvalida.error}`
  );

  // 6. Listar con filtro
  const filtrado = await fetch(`${BASE}/pedidos?estado=EN_PROCESO&ordenarPor=total&orden=desc`);
  const cuerpoFiltrado = await filtrado.json();
  registrar(
    "GET /pedidos filtra por estado y ordena por total",
    filtrado.status === 200 && cuerpoFiltrado.datos.every((p: { estado: string }) => p.estado === "EN_PROCESO"),
    `HTTP ${filtrado.status} - ${cuerpoFiltrado.total} pedidos en EN_PROCESO`
  );

  // 7. Validacion
  const malo = await fetch(`${BASE}/pedidos`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ cliente: "Sin datos", items: [] }),
  });
  const cuerpoMalo = await malo.json();
  registrar(
    "POST /pedidos con datos invalidos devuelve 400",
    malo.status === 400 && Array.isArray(cuerpoMalo.detalles),
    `HTTP ${malo.status} - campos: ${cuerpoMalo.detalles?.map((d: { campo: string }) => d.campo).join(", ")}`
  );

  // 8. Inexistente
  const inexistente = await fetch(`${BASE}/pedidos/00000000-0000-0000-0000-000000000000`);
  registrar(
    "GET /pedidos/{id} inexistente devuelve 404",
    inexistente.status === 404,
    `HTTP ${inexistente.status}`
  );

  console.log(`\n${"=".repeat(72)}`);
  console.log(`RESULTADO: ${superadas}/${total} pruebas superadas`);
  console.log("=".repeat(72));
  process.exit(superadas === total ? 0 : 1);
}

main().catch((error) => {
  console.error("\nError ejecutando las pruebas:", error instanceof Error ? error.message : error);
  console.error(`Verifique que la API responda en ${BASE}`);
  process.exit(1);
});
