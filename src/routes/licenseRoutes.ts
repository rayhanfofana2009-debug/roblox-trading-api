import { FastifyInstance } from "fastify";
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

const licenseVerifyBody = z.object({
  userId: z.coerce.bigint(),
  licenseId: z.string().uuid()
}); // Per-instance verification route

const transferParams = z.object({
  licenseId: z.string().uuid()
});

const transferBody = z.object({
  fromUserId: z.coerce.bigint(),
  toUserId: z.coerce.bigint(),
  universeId: z.coerce.bigint()
});

const tradeHistoryQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20)
});

const claimBody = z.object({
    userId: z.coerce.bigint(),
    gamepassId: z.coerce.bigint(),
    universeId: z.coerce.bigint(),
    secret: z.string()
});

const executeTradeBody = z.object({
  fromUserId: z.coerce.bigint(),
  toUserId: z.coerce.bigint(),
  universeId: z.coerce.bigint(),
  fromLicenses: z.array(z.string().uuid()),
  toLicenses: z.array(z.string().uuid())
});

export async function registerLicenseRoutes(app: FastifyInstance) {
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

  app.post("/v1/licenses/verify-instance", async (request, reply) => {
    const parsedBody = licenseVerifyBody.safeParse(request.body);
    if (!parsedBody.success) {
      return reply.badRequest("Invalid request body.");
    }

    const { userId, licenseId } = parsedBody.data;

    const license = await prisma.license.findUnique({
      where: {
        id: licenseId
      },
      select: {
        ownerUserId: true,
        status: true
      }
    });

    const isValid = license &&
                    license.ownerUserId === userId &&
                    license.status === LicenseStatus.ACTIVE;

    return reply.send({
      data: {
        valid: isValid
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
    const { fromUserId, toUserId, universeId } = parsedBody.data;

    if (fromUserId === toUserId) {
      return reply.badRequest("fromUserId and toUserId must be different.");
    }

    // Validate that transfer is only allowed from trading universe
    const tradingUniverseId = process.env.TRADING_UNIVERSE_ID;
    if (!tradingUniverseId) {
      return reply.internalServerError("TRADING_UNIVERSE_ID not configured.");
    }

    if (universeId.toString() !== tradingUniverseId) {
      return reply.status(403).send({ error: "Transfers are only allowed from the trading game." });
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
    } catch (error) {
      if (error instanceof Error) {
        if (error.message === "LICENSE_NOT_OWNED_OR_NOT_ACTIVE") {
          return reply.status(409).send({ error: "License is not active or not owned by fromUserId." });
        }
        if (error.message === "RECIPIENT_ALREADY_HAS_NON_STACKABLE_LICENSE") {
          return reply.status(409).send({ error: "Recipient already owns this non-stackable license type." });
        }
        if (error.message === "LICENSE_NOT_FOUND") {
          return reply.status(404).send({ error: "License not found." });
        }
      }
      throw error;
    }
  });

  app.post("/v1/trades/execute", async (request, reply) => {
    const parsedBody = executeTradeBody.safeParse(request.body);
    if (!parsedBody.success) {
      return reply.badRequest("Invalid request body.");
    }

    const { fromUserId, toUserId, universeId, fromLicenses, toLicenses } = parsedBody.data;

    if (fromUserId === toUserId) {
      return reply.badRequest("fromUserId and toUserId must be different.");
    }

    if (fromLicenses.length === 0 && toLicenses.length === 0) {
      return reply.badRequest("At least one license must be specified in the trade.");
    }

    // Validate that transfer is only allowed from trading universe
    const tradingUniverseId = process.env.TRADING_UNIVERSE_ID;
    if (!tradingUniverseId) {
      return reply.internalServerError("TRADING_UNIVERSE_ID not configured.");
    }

    if (universeId.toString() !== tradingUniverseId) {
      return reply.status(403).send({ error: "Transfers are only allowed from the trading game." });
    }

    try {
      const result = await prisma.$transaction(async (tx) => {
        // Lock all licenses from both sides
        const allLicenseIds = [...fromLicenses, ...toLicenses];
        
        const lockedLicenses = await tx.license.findMany({
          where: {
            id: { in: allLicenseIds },
            status: LicenseStatus.ACTIVE
          },
          include: { licenseType: true }
        });

        if (lockedLicenses.length !== allLicenseIds.length) {
          throw new Error("ONE_OR_MORE_LICENSES_NOT_FOUND_OR_NOT_ACTIVE");
        }

        // Verify ownership of all licenses
        for (const license of lockedLicenses) {
          const isFromSide = fromLicenses.includes(license.id);
          const expectedOwner = isFromSide ? fromUserId : toUserId;
          
          if (license.ownerUserId !== expectedOwner) {
            throw new Error("LICENSE_OWNERSHIP_MISMATCH");
          }
        }

        // Check non-stackable constraints for all recipients
        for (const license of lockedLicenses) {
          if (!license.licenseType.stackable) {
            const isFromSide = fromLicenses.includes(license.id);
            const recipient = isFromSide ? toUserId : fromUserId;
            
            const recipientExisting = await tx.license.findFirst({
              where: {
                ownerUserId: recipient,
                licenseTypeId: license.licenseTypeId,
                status: LicenseStatus.ACTIVE
              },
              select: { id: true }
            });

            if (recipientExisting) {
              throw new Error("RECIPIENT_ALREADY_HAS_NON_STACKABLE_LICENSE");
            }
          }
        }

        // Lock all licenses
        await tx.license.updateMany({
          where: {
            id: { in: allLicenseIds }
          },
          data: {
            status: LicenseStatus.LOCKED_IN_TRADE
          }
        });

        // Create trade record
        const trade = await tx.trade.create({
          data: {
            initiatorUserId: fromUserId,
            counterpartyUserId: toUserId,
            status: TradeStatus.COMPLETED,
            completedAt: new Date()
          }
        });

        // Create trade items and transfer licenses
        const transferredLicenses = [];

        for (const license of lockedLicenses) {
          const isFromSide = fromLicenses.includes(license.id);
          const newOwner = isFromSide ? toUserId : fromUserId;
          const side = isFromSide ? TradeSide.INITIATOR : TradeSide.COUNTERPARTY;
          const originalOwner = license.ownerUserId;

          await tx.tradeItem.create({
            data: {
              tradeId: trade.id,
              side: side,
              licenseId: license.id,
              fromUserId: originalOwner
            }
          });

          const updatedLicense = await tx.license.update({
            where: { id: license.id },
            data: {
              ownerUserId: newOwner,
              status: LicenseStatus.ACTIVE,
              origin: LicenseOrigin.TRADE
            }
          });

          await tx.ownershipEvent.create({
            data: {
              licenseId: license.id,
              fromUserId: originalOwner,
              toUserId: newOwner,
              reason: "TRADE_TRANSFER",
              tradeId: trade.id
            }
          });

          transferredLicenses.push({
            licenseId: updatedLicense.id,
            fromUserId: originalOwner.toString(),
            toUserId: newOwner.toString()
          });
        }

        return { trade, transferredLicenses };
      });

      return reply.send({
        data: {
          tradeId: result.trade.id,
          fromUserId: fromUserId.toString(),
          toUserId: toUserId.toString(),
          transferredAt: result.trade.completedAt,
          transferredLicenses: result.transferredLicenses
        }
      });
    } catch (error) {
      if (error instanceof Error) {
        if (error.message === "ONE_OR_MORE_LICENSES_NOT_FOUND_OR_NOT_ACTIVE") {
          return reply.status(409).send({ error: "One or more licenses are not active or not owned by the specified users." });
        }
        if (error.message === "LICENSE_OWNERSHIP_MISMATCH") {
          return reply.status(409).send({ error: "License ownership mismatch. One or more licenses are not owned by the specified users." });
        }
        if (error.message === "RECIPIENT_ALREADY_HAS_NON_STACKABLE_LICENSE") {
          return reply.status(409).send({ error: "One or more recipients already owns a non-stackable license type from this trade." });
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

  app.post("/v1/license/claim", async (request, reply) => {
    const parsedBody = claimBody.safeParse(request.body);

    if (parsedBody.success) {
      request.log.info({
        userId: parsedBody.data.userId,
        gamepassId: parsedBody.data.gamepassId,
        universeId: parsedBody.data.universeId
      }, "Incoming claim request");
    }
    if (!parsedBody.success) {
      request.log.error({
        errors: parsedBody.error.flatten()
      }, "Claim validation failed");

      return reply.status(400).send({
        error: parsedBody.error.flatten()
      });
    }

    const { userId, gamepassId, universeId, secret } = parsedBody.data;

    // Verify secret (you should set this as an environment variable)
    const expectedSecret = process.env.CLAIM_SECRET || "your-claim-secret-change-this";
    if (secret !== expectedSecret) {
      return reply.unauthorized("Invalid secret.");
    }

    try {
      // Find purchase source for this gamepass
      const purchaseSource = await prisma.purchaseSource.findUnique({
        where: {
          universeId_gamepassId: {
            universeId: universeId,
            gamepassId
          }
        },
        include: {
          licenseType: true
        }
      });

      if (!purchaseSource) {
        return reply.notFound("Gamepass not registered in system.");
      }

      // A Game Pass may create only one transferable license, ever.
      // The license may be traded, but the original buyer must not claim another.
      const previousClaim = await prisma.purchase.findFirst({
        where: {
          buyerUserId: userId,
          licenseTypeId: purchaseSource.licenseTypeId
        },
        orderBy: {
          createdAt: "asc"
        }
      });

      if (previousClaim) {
        const originalLicense = await prisma.license.findFirst({
          where: {
            createdFromPurchaseId: previousClaim.id
          },
          select: {
            id: true,
            licenseTypeId: true
          }
        });

        return reply.send({
          data: {
            success: true,
            alreadyClaimed: true,
            licenseId: originalLicense?.id ?? "00000000-0000-0000-0000-000000000000",
            licenseTypeId: purchaseSource.licenseTypeId,
            displayName: purchaseSource.licenseType.displayName
          }
        });
      }

      // Create purchase record (historical record only - does not prevent future claims)
      const purchase = await prisma.purchase.create({
        data: {
          robloxReceiptId: `claim_${userId}_${purchaseSource.licenseTypeId}_${Date.now()}`,
          buyerUserId: userId,
          licenseTypeId: purchaseSource.licenseTypeId
        }
      });

      // Create new license linked to purchase
      const license = await prisma.license.create({
        data: {
          licenseTypeId: purchaseSource.licenseTypeId,
          ownerUserId: userId,
          status: LicenseStatus.ACTIVE,
          origin: LicenseOrigin.PURCHASE,
          createdFromPurchaseId: purchase.id
        },
        include: {
          licenseType: true
        }
      });

      // Create ownership event
      await prisma.ownershipEvent.create({
        data: {
          licenseId: license.id,
          toUserId: userId,
          reason: "GAMEPASS_CLAIM",
          purchaseId: purchase.id
        }
      });

      return reply.send({
        data: {
          success: true,
          alreadyClaimed: false,
          licenseId: license.id,
          licenseTypeId: license.licenseTypeId,
          displayName: license.licenseType.displayName
        }
      });
    } catch (error) {
      request.log.error(error);
      if (error instanceof Error) {
        return reply.internalServerError(error.message);
      }
      throw error;
    }
  });
}
