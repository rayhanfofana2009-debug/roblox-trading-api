import { createHash } from "node:crypto";
import { prisma } from "./db.js";

export function hashApiKey(rawKey: string): string {
  return createHash("sha256").update(rawKey).digest("hex");
}

export async function findApiClientByKey(rawKey: string) {
  const keyHash = hashApiKey(rawKey);
  return prisma.apiClient.findUnique({ where: { keyHash } });
}
