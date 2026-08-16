import "dotenv/config";
import Fastify from "fastify";
import sensible from "@fastify/sensible";
import type { ApiClient } from "@prisma/client";
import { registerPurchaseRoutes } from "./routes/purchaseRoutes.js";
import { registerLicenseRoutes } from "./routes/licenseRoutes.js";
import { findApiClientByKey } from "./authHelpers.js";

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? "0.0.0.0";
const API_KEY = process.env.API_KEY;

const app = Fastify({ logger: true });

await app.register(sensible);

declare module "fastify" {
  interface FastifyRequest {
    // Present only when a scoped per-game key (not the master API_KEY)
    // was used to authenticate this request.
    apiClient?: ApiClient;
  }
}

// Routes a scoped per-game key is allowed to call at all.
// Everything else requires the master API_KEY.
const SCOPED_CLIENT_ROUTES = new Set([
  "/v1/license/claim",
  "/v1/licenses/verify"
]);

app.addHook("onRequest", async (request, reply) => {
  if (request.url === "/health") {
    return;
  }

  const authHeader = request.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return reply.code(401).send({ error: "Missing or invalid Authorization header" });
  }

  const token = authHeader.substring(7);

  // Master admin key: unrestricted access to every route.
  if (token === API_KEY) {
    return;
  }

  // Not the master key - only usable on the two scoped, per-game routes.
  const routePath = request.url.split("?")[0];
  if (!SCOPED_CLIENT_ROUTES.has(routePath)) {
    return reply.code(401).send({ error: "Invalid API key" });
  }

  const client = await findApiClientByKey(token);
  if (!client) {
    return reply.code(401).send({ error: "Invalid API key" });
  }

  request.apiClient = client;
});

await registerPurchaseRoutes(app);
await registerLicenseRoutes(app);

app.get("/health", async () => ({ ok: true }));

app.setErrorHandler((error, request, reply) => {
  request.log.error(error);
  if (!reply.sent) {
    void reply.code(500).send({
      error: "Internal server error."
    });
  }
});

try {
  await app.listen({ port, host });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
