import "dotenv/config";
import Fastify from "fastify";
import sensible from "@fastify/sensible";
import { registerPurchaseRoutes } from "./routes/purchaseRoutes.js";
import { registerLicenseRoutes } from "./routes/licenseRoutes.js";
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? "0.0.0.0";
const app = Fastify({ logger: true });
await app.register(sensible);
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
}
catch (error) {
    app.log.error(error);
    process.exit(1);
}
