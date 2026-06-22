import { prisma } from "../db.js";
import { z } from "zod";
import { LicenseOrigin, LicenseStatus, TradeSide, TradeStatus } from "@prisma/client";
const playerParams = z.object({
    userId: z.coerce.bigint()
});
const licenseQuery = z.object({
    licenseTypeId: z.string().uuid().optional(),
    activeOnly: z.coerce.boolean().default(true)
});
const ownershipVerifyQuery = z.object({
    userId: z.coerce.bigint(),
    licenseTypeId: z.string().uuid()
});
const transferParams = z.object({
    licenseId: z.string().uuid()
});
const transferBody = z.object({
    fromUserId: z.coerce.bigint(),
    toUserId: z.coerce.bigint()
});
const tradeHistoryQuery = z.object({
    limit: z.coerce.number().int().min(1).max(100).default(20)
});
export async function registerLicenseRoutes(app) {
    app.get("/v1/players/:userId/licenses", async (request, reply) => {
        const parsedParams = playerParams.safeParse(request.params);
        if (!parsedParams.success) {
            return reply.badRequest("Invalid user id.");
        }
        const parsedQuery = licenseQuery.safeParse(request.query);
        if (!parsedQuery.success) {
            return reply.badRequest("Invalid query.");
        }
        const { userId } = parsedParams.data;
        const { licenseTypeId, activeOnly } = parsedQuery.data;
        const licenses = await prisma.license.findMany({
            where: {
                ownerUserId: userId,
                ...(licenseTypeId ? { licenseTypeId } : {}),
                ...(activeOnly ? { status: "ACTIVE" } : {})
            },
            include: {
                licenseType: true
            },
            orderBy: {
                createdAt: "desc"
            }
        });
        return reply.send({
            data: licenses.map((license) => ({
                licenseId: license.id,
                licenseTypeId: license.licenseTypeId,
                displayName: license.licenseType.displayName,
                ownerUserId: license.ownerUserId.toString(),
                status: license.status,
                origin: license.origin,
                createdAt: license.createdAt
            }))
        });
    });
    app.get("/v1/licenses/verify", async (request, reply) => {
        const parsedQuery = ownershipVerifyQuery.safeParse(request.query);
        if (!parsedQuery.success) {
            return reply.badRequest("Invalid query.");
        }
        const { userId, licenseTypeId } = parsedQuery.data;
        const activeLicense = await prisma.license.findFirst({
            where: {
                ownerUserId: userId,
                licenseTypeId,
                status: LicenseStatus.ACTIVE
            },
            select: {
                id: true,
                ownerUserId: true,
                licenseTypeId: true,
                updatedAt: true
            }
        });
        return reply.send({
            data: {
                userId: userId.toString(),
                licenseTypeId,
                ownsLicense: Boolean(activeLicense),
                license: activeLicense
                    ? {
                        licenseId: activeLicense.id,
                        ownerUserId: activeLicense.ownerUserId.toString(),
                        updatedAt: activeLicense.updatedAt
                    }
                    : null
            }
        });
    });
    app.post("/v1/licenses/:licenseId/transfer", async (request, reply) => {
        const parsedParams = transferParams.safeParse(request.params);
        if (!parsedParams.success) {
            return reply.badRequest("Invalid license id.");
        }
        const parsedBody = transferBody.safeParse(request.body);
        if (!parsedBody.success) {
            return reply.badRequest("Invalid request body.");
        }
        const { licenseId } = parsedParams.data;
        const { fromUserId, toUserId } = parsedBody.data;
        if (fromUserId === toUserId) {
            return reply.badRequest("fromUserId and toUserId must be different.");
        }
        try {
            const result = await prisma.$transaction(async (tx) => {
                const lockResult = await tx.license.updateMany({
                    where: {
                        id: licenseId,
                        ownerUserId: fromUserId,
                        status: LicenseStatus.ACTIVE
                    },
                    data: {
                        status: LicenseStatus.LOCKED_IN_TRADE
                    }
                });
                if (lockResult.count !== 1) {
                    throw new Error("LICENSE_NOT_OWNED_OR_NOT_ACTIVE");
                }
                const lockedLicense = await tx.license.findUnique({
                    where: { id: licenseId },
                    include: { licenseType: true }
                });
                if (!lockedLicense) {
                    throw new Error("LICENSE_NOT_FOUND");
                }
                if (!lockedLicense.licenseType.stackable) {
                    const recipientExisting = await tx.license.findFirst({
                        where: {
                            ownerUserId: toUserId,
                            licenseTypeId: lockedLicense.licenseTypeId,
                            status: LicenseStatus.ACTIVE
                        },
                        select: { id: true }
                    });
                    if (recipientExisting) {
                        throw new Error("RECIPIENT_ALREADY_HAS_NON_STACKABLE_LICENSE");
                    }
                }
                const trade = await tx.trade.create({
                    data: {
                        initiatorUserId: fromUserId,
                        counterpartyUserId: toUserId,
                        status: TradeStatus.COMPLETED,
                        completedAt: new Date()
                    }
                });
                await tx.tradeItem.create({
                    data: {
                        tradeId: trade.id,
                        side: TradeSide.INITIATOR,
                        licenseId,
                        fromUserId
                    }
                });
                const updatedLicense = await tx.license.update({
                    where: { id: licenseId },
                    data: {
                        ownerUserId: toUserId,
                        status: LicenseStatus.ACTIVE,
                        origin: LicenseOrigin.TRADE
                    }
                });
                await tx.ownershipEvent.create({
                    data: {
                        licenseId,
                        fromUserId,
                        toUserId,
                        reason: "TRADE_TRANSFER",
                        tradeId: trade.id
                    }
                });
                return { trade, updatedLicense };
            });
            return reply.send({
                data: {
                    tradeId: result.trade.id,
                    licenseId: result.updatedLicense.id,
                    fromUserId: fromUserId.toString(),
                    toUserId: toUserId.toString(),
                    transferredAt: result.trade.completedAt
                }
            });
        }
        catch (error) {
            if (error instanceof Error) {
                if (error.message === "LICENSE_NOT_OWNED_OR_NOT_ACTIVE") {
                    return reply.conflict("License is not active or not owned by fromUserId.");
                }
                if (error.message === "RECIPIENT_ALREADY_HAS_NON_STACKABLE_LICENSE") {
                    return reply.conflict("Recipient already owns this non-stackable license type.");
                }
                if (error.message === "LICENSE_NOT_FOUND") {
                    return reply.notFound("License not found.");
                }
            }
            throw error;
        }
    });
    app.get("/v1/players/:userId/trades", async (request, reply) => {
        const parsedParams = playerParams.safeParse(request.params);
        if (!parsedParams.success) {
            return reply.badRequest("Invalid user id.");
        }
        const parsedQuery = tradeHistoryQuery.safeParse(request.query);
        if (!parsedQuery.success) {
            return reply.badRequest("Invalid query.");
        }
        const { userId } = parsedParams.data;
        const { limit } = parsedQuery.data;
        const trades = await prisma.trade.findMany({
            where: {
                OR: [{ initiatorUserId: userId }, { counterpartyUserId: userId }]
            },
            orderBy: {
                createdAt: "desc"
            },
            take: limit,
            include: {
                items: {
                    include: {
                        license: {
                            include: {
                                licenseType: true
                            }
                        }
                    }
                }
            }
        });
        return reply.send({
            data: trades.map((trade) => ({
                tradeId: trade.id,
                status: trade.status,
                initiatorUserId: trade.initiatorUserId.toString(),
                counterpartyUserId: trade.counterpartyUserId.toString(),
                createdAt: trade.createdAt,
                completedAt: trade.completedAt,
                items: trade.items.map((item) => ({
                    tradeItemId: item.id,
                    side: item.side,
                    fromUserId: item.fromUserId.toString(),
                    licenseId: item.licenseId,
                    licenseTypeId: item.license.licenseTypeId,
                    licenseDisplayName: item.license.licenseType.displayName
                }))
            }))
        });
    });
}
