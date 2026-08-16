// Usage: node --loader ts-node/esm scripts/createApiClient.ts "Game Name" 123456789
import { randomBytes } from "node:crypto";
import { prisma } from "../src/db.js";
import { hashApiKey } from "../src/authHelpers.js";

async function main() {
  const [name, universeIdStr] = process.argv.slice(2);
  if (!name || !universeIdStr) {
    console.error("Usage: createApiClient.ts <name> <allowedUniverseId>");
    process.exit(1);
  }

  const rawKey = randomBytes(32).toString("hex");

  const client = await prisma.apiClient.create({
    data: {
      name,
      keyHash: hashApiKey(rawKey),
      allowedUniverseId: BigInt(universeIdStr)
    }
  });

  console.log("ApiClient created:", client.id);
  console.log("Give this key to the developer (shown only once):");
  console.log(rawKey);
}

main()
  .catch((err) => { console.error(err); process.exit(1); })
  .finally(() => prisma.$disconnect());
