/**
 * Almacen de pedidos.
 *
 * Se define una interfaz y dos implementaciones: DynamoDB para los entornos
 * desplegados y memoria para las pruebas unitarias. Gracias a eso las
 * pruebas corren en CodeBuild sin credenciales ni red, en milisegundos.
 */
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  GetCommand,
  ScanCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import type { Pedido, Estado } from "../dominio/pedidos";

export interface AlmacenPedidos {
  guardar(pedido: Pedido): Promise<Pedido>;
  obtener(id: string): Promise<Pedido | undefined>;
  listar(): Promise<Pedido[]>;
  cambiarEstado(id: string, estado: Estado): Promise<Pedido | undefined>;
}

/** Implementacion en memoria, usada por las pruebas unitarias. */
export class AlmacenEnMemoria implements AlmacenPedidos {
  private readonly datos = new Map<string, Pedido>();

  async guardar(pedido: Pedido): Promise<Pedido> {
    this.datos.set(pedido.id, pedido);
    return pedido;
  }

  async obtener(id: string): Promise<Pedido | undefined> {
    return this.datos.get(id);
  }

  async listar(): Promise<Pedido[]> {
    return [...this.datos.values()];
  }

  async cambiarEstado(id: string, estado: Estado): Promise<Pedido | undefined> {
    const pedido = this.datos.get(id);
    if (!pedido) return undefined;
    const actualizado: Pedido = { ...pedido, estado, actualizadoEn: new Date().toISOString() };
    this.datos.set(id, actualizado);
    return actualizado;
  }
}

/**
 * Implementacion sobre DynamoDB.
 *
 * El nombre de la tabla llega por variable de entorno, de modo que la misma
 * imagen sirve para el entorno de pruebas y para el de produccion: solo
 * cambia la definicion de tarea que la ejecuta.
 */
export class AlmacenDynamoDB implements AlmacenPedidos {
  private readonly cliente: DynamoDBDocumentClient;

  constructor(private readonly tabla: string, region = process.env.AWS_REGION ?? "us-east-1") {
    this.cliente = DynamoDBDocumentClient.from(new DynamoDBClient({ region }), {
      marshallOptions: { removeUndefinedValues: true },
    });
  }

  async guardar(pedido: Pedido): Promise<Pedido> {
    await this.cliente.send(new PutCommand({ TableName: this.tabla, Item: pedido }));
    return pedido;
  }

  async obtener(id: string): Promise<Pedido | undefined> {
    const r = await this.cliente.send(new GetCommand({ TableName: this.tabla, Key: { id } }));
    return r.Item as Pedido | undefined;
  }

  /**
   * Scan recorre la tabla completa. Para el volumen de este ejercicio es
   * suficiente y mantiene el codigo simple; en produccion real, filtrar por
   * estado se resolveria con un indice secundario global sobre ese campo.
   */
  async listar(): Promise<Pedido[]> {
    const r = await this.cliente.send(new ScanCommand({ TableName: this.tabla }));
    return (r.Items ?? []) as Pedido[];
  }

  async cambiarEstado(id: string, estado: Estado): Promise<Pedido | undefined> {
    const r = await this.cliente.send(
      new UpdateCommand({
        TableName: this.tabla,
        Key: { id },
        UpdateExpression: "SET #e = :e, actualizadoEn = :a",
        ExpressionAttributeNames: { "#e": "estado" },
        ExpressionAttributeValues: { ":e": estado, ":a": new Date().toISOString() },
        ConditionExpression: "attribute_exists(id)",
        ReturnValues: "ALL_NEW",
      })
    );
    return r.Attributes as Pedido | undefined;
  }
}
