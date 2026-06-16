import "dotenv/config";
import Fastify from "fastify";
import sensible from "@fastify/sensible";
import { registerPurchaseRoutes } from "./routes/purchaseRoutes.js";
import { registerLicenseRoutes } from "./routes/licenseRoutes.js";

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? "0.0.0.0";
const API_KEY = process.env.API_KEY;

const app = Fastify({ logger: true });

await app.register(sensible);

// Authentication middleware for API routes
app.addHook("onRequest", async (request, reply) => {
  // Skip authentication for health endpoint and claim endpoint
  if (request.url === "/health" || request.url.startsWith("/v1/license/claim")) {
    return;
  }

  // Check for API key in Authorization header
  const authHeader = request.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return reply.code(401).send({ error: "Missing or invalid Authorization header" });
  }

  const token = authHeader.substring(7); // Remove "Bearer " prefix
  if (token !== API_KEY) {
    return reply.code(401).send({ error: "Invalid API key" });
  }
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
