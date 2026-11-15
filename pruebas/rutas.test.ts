/**
 * Pruebas de las rutas HTTP.
 *
 * Levantan la aplicacion sobre un puerto efimero con el almacen en memoria,
 * de modo que no hace falta DynamoDB ni credenciales de AWS. Comprueban los
 * codigos de estado y el contrato de la API.
 */
import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import type { Server } from "node:http";
import { crearApp } from "../src/app";
import { AlmacenEnMemoria } from "../src/almacen/pedidos";

let servidor: Server;
let base: string;

const PEDIDO = {
  cliente: "Andres Gomez",
  correoCliente: "andres@lasalle.edu.co",
  direccionEnvio: "Calle 80 #20-15, Bogota",
  items: [{ producto: "Monitor 27 pulgadas", cantidad: 1, precioUnitario: 950000 }],
};

before(async () => {
  const app = crearApp(new AlmacenEnMemoria());
  await new Promise<void>((resolver) => {
    servidor = app.listen(0, "127.0.0.1", () => resolver());
  });
  const direccion = servidor.address();
  const puerto = typeof direccion === "object" && direccion ? direccion.port : 0;
  base = `http://127.0.0.1:${puerto}`;
});

after(() => servidor?.close());

describe("GET /health", () => {
  test("responde 200 con el estado del servicio", async () => {
    const r = await fetch(`${base}/health`);
    const cuerpo = await r.json();
    assert.equal(r.status, 200);
    assert.equal(cuerpo.estado, "ok");
    assert.equal(cuerpo.servicio, "api-pedidos");
  });
});

describe("POST /pedidos", () => {
  test("crea el pedido y devuelve 201 con la cabecera Location", async () => {
    const r = await fetch(`${base}/pedidos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(PEDIDO),
    });
    const cuerpo = await r.json();
    assert.equal(r.status, 201);
    assert.equal(cuerpo.estado, "PENDIENTE");
    assert.equal(cuerpo.total, 950000);
    assert.equal(r.headers.get("location"), `/pedidos/${cuerpo.id}`);
  });

  test("devuelve 400 con el detalle de los campos invalidos", async () => {
    const r = await fetch(`${base}/pedidos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cliente: "Sin correo", items: [] }),
    });
    const cuerpo = await r.json();
    assert.equal(r.status, 400);
    assert.ok(Array.isArray(cuerpo.detalles));
    assert.ok(cuerpo.detalles.length >= 2);
  });

  test("devuelve 400 cuando el cuerpo no es JSON valido", async () => {
    const r = await fetch(`${base}/pedidos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{ esto no es json",
    });
    assert.equal(r.status, 400);
  });
});

describe("GET /pedidos", () => {
  test("lista los pedidos con su total y los metadatos de filtro", async () => {
    const r = await fetch(`${base}/pedidos`);
    const cuerpo = await r.json();
    assert.equal(r.status, 200);
    assert.ok(cuerpo.total >= 1);
    assert.ok(Array.isArray(cuerpo.datos));
    assert.equal(cuerpo.orden.campo, "creadoEn");
  });

  test("rechaza un filtro de estado inexistente", async () => {
    const r = await fetch(`${base}/pedidos?estado=INVENTADO`);
    assert.equal(r.status, 400);
  });
});

describe("GET /pedidos/:id", () => {
  test("devuelve 404 para un identificador desconocido", async () => {
    const r = await fetch(`${base}/pedidos/00000000-0000-0000-0000-000000000000`);
    assert.equal(r.status, 404);
  });
});

describe("PATCH /pedidos/:id/estado", () => {
  let id: string;

  before(async () => {
    const r = await fetch(`${base}/pedidos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(PEDIDO),
    });
    id = (await r.json()).id;
  });

  test("avanza el pedido al siguiente estado valido", async () => {
    const r = await fetch(`${base}/pedidos/${id}/estado`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ estado: "EN_PROCESO" }),
    });
    const cuerpo = await r.json();
    assert.equal(r.status, 200);
    assert.equal(cuerpo.estado, "EN_PROCESO");
  });

  test("devuelve 409 ante una transicion no permitida", async () => {
    const r = await fetch(`${base}/pedidos/${id}/estado`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ estado: "PENDIENTE" }),
    });
    const cuerpo = await r.json();
    assert.equal(r.status, 409);
    assert.equal(cuerpo.error, "TransicionNoPermitida");
    assert.ok(Array.isArray(cuerpo.transicionesPermitidas));
  });

  test("devuelve 400 si el estado no existe", async () => {
    const r = await fetch(`${base}/pedidos/${id}/estado`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ estado: "VOLANDO" }),
    });
    assert.equal(r.status, 400);
  });

  test("devuelve 404 si el pedido no existe", async () => {
    const r = await fetch(`${base}/pedidos/00000000-0000-0000-0000-000000000000/estado`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ estado: "EN_PROCESO" }),
    });
    assert.equal(r.status, 404);
  });
});
