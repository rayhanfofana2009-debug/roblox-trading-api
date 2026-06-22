import { prisma } from "../db.js";
import { LicenseOrigin, LicenseStatus } from "@prisma/client";
import { z } from "zod";
const verifyPurchaseBody = z.object({
    robloxReceiptId: z.string().min(1),
    buyerUserId: z.coerce.bigint(),
    universeId: z.coerce.bigint(),
    gamepassId: z.coerce.bigint()
});
export async function registerPurchaseRoutes(app) {
    app.post("/v1/purchases/verify", async (request, reply) => {
        const parsed = verifyPurchaseBody.safeParse(request.body);
        if (!parsed.success) {
            return reply.badRequest("Invalid request body.");
        }
        const { robloxReceiptId, buyerUserId, universeId, gamepassId } = parsed.data;
        const source = await prisma.purchaseSource.findUnique({
            where: {
                universeId_gamepassId: { universeId, gamepassId }
            }
        });
        if (!source) {
            return reply.notFound("No mapped license type for this universe/gamepass.");
        }
        const existingByReceipt = await prisma.purchase.findUnique({
            where: { robloxReceiptId },
            include: { license: true }
        });
        if (existingByReceipt) {
            return reply.send({
                data: {
                    purchaseId: existingByReceipt.id,
                    licenseId: existingByReceipt.license?.id ?? null,
                    idempotentReplay: true
                }
            });
        }
        const existingByBuyerAndType = await prisma.purchase.findUnique({
            where: {
                buyerUserId_licenseTypeId: {
                    buyerUserId,
                    licenseTypeId: source.licenseTypeId
                }
            },
            include: { license: true }
        });
        if (existingByBuyerAndType) {
            return reply.conflict("Player already purchased this license type.");
        }
        const created = await prisma.$transaction(async (tx) => {
            const purchase = await tx.purchase.create({
                data: {
                    robloxReceiptId,
                    buyerUserId,
                    licenseTypeId: source.licenseTypeId
                }
            });
            const license = await tx.license.create({
                data: {
                    licenseTypeId: source.licenseTypeId,
                    ownerUserId: buyerUserId,
                    status: LicenseStatus.ACTIVE,
                    origin: LicenseOrigin.PURCHASE,
                    createdFromPurchaseId: purchase.id
                }
            });
            await tx.ownershipEvent.create({
                data: {
                    licenseId: license.id,
                    fromUserId: null,
                    toUserId: buyerUserId,
                    reason: "PURCHASE_MINT",
                    purchaseId: purchase.id
                }
            });
            return { purchase, license };
        });
        return reply.code(201).send({
            data: {
                purchaseId: created.purchase.id,
                licenseId: created.license.id,
                idempotentReplay: false
            }
        });
    });
}
