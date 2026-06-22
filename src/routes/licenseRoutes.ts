import { FastifyInstance } from "fastify";
import { prisma } from "../db.js";
import { z } from "zod";
import { LicenseOrigin, LicenseStatus, TradeSide, TradeStatus } from "@prisma/client";
import { getUserGamepasses } from "../services/robloxApi.js";

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

  app.post("/v1/players/:userId/sync-licenses", async (request, reply) => {
    const parsedParams = playerParams.safeParse(request.params);
    if (!parsedParams.success) {
      return reply.badRequest("Invalid user id.");
    }

    const { userId } = parsedParams.data;

    const syncBody = z.object({
      universeId: z.coerce.bigint()
    });

    const parsedBody = syncBody.safeParse(request.body);
    if (!parsedBody.success) {
      return reply.badRequest("Invalid request body. universeId is required.");
    }

    const { universeId } = parsedBody.data;

    try {
      // Get all registered gamepasses from database for this universe
      const purchaseSources = await prisma.purchaseSource.findMany({
        where: {
          universeId: universeId
        },
        include: {
          licenseType: true
        }
      });

      request.log.info(`Found ${purchaseSources.length} purchase sources in database for universe ${universeId}`);

      // Get gamepasses user owns on Roblox
      const ownedGamepasses = await getUserGamepasses(userId, universeId);

      request.log.info(`User ${userId} owns ${ownedGamepasses.length} gamepasses on Roblox: ${ownedGamepasses.map(id => id.toString()).join(', ')}`);

      // Get existing licenses for user
      const existingLicenses = await prisma.license.findMany({
        where: {
          ownerUserId: userId
        },
        select: {
          licenseTypeId: true
        }
      });

      request.log.info(`User ${userId} has ${existingLicenses.length} existing licenses in database`);

      const existingLicenseTypeIds = new Set(existingLicenses.map(l => l.licenseTypeId));
      const createdLicenses = [];

      // Create missing licenses for owned gamepasses
      for (const source of purchaseSources) {
        request.log.info(`Checking gamepass ${source.gamepassId} -> license type ${source.licenseTypeId}`);

        // Check if user owns this gamepass on Roblox
        if (!ownedGamepasses.includes(source.gamepassId)) {
          request.log.info(`User does not own gamepass ${source.gamepassId} on Roblox`);
          continue;
        }

        request.log.info(`User owns gamepass ${source.gamepassId} on Roblox`);

        // Check if license already exists in database
        if (existingLicenseTypeIds.has(source.licenseTypeId)) {
          request.log.info(`License already exists for type ${source.licenseTypeId}`);
          continue;
        }

        request.log.info(`Creating license for type ${source.licenseTypeId}`);

        // Create license
        const license = await prisma.license.create({
          data: {
            licenseTypeId: source.licenseTypeId,
            ownerUserId: userId,
            status: LicenseStatus.ACTIVE,
            origin: LicenseOrigin.PURCHASE
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
            reason: "SYNC_FROM_ROBLOX"
          }
        });

        createdLicenses.push({
          licenseId: license.id,
          licenseTypeId: license.licenseTypeId,
          displayName: license.licenseType.displayName
        });
      }

      return reply.send({
        data: {
          userId: userId.toString(),
          universeId: universeId.toString(),
          createdCount: createdLicenses.length,
          createdLicenses
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

  app.post("/v1/license/claim", async (request, reply) => {
    const parsedBody = claimBody.safeParse(request.body);
    if (!parsedBody.success) {
      return reply.badRequest("Invalid request body.");
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

      // Check if user already has a license for this gamepass
      const existingLicense = await prisma.license.findFirst({
        where: {
          ownerUserId: userId,
          licenseTypeId: purchaseSource.licenseTypeId,
          status: LicenseStatus.ACTIVE
        }
      });

      if (existingLicense) {
        return reply.send({
          data: {
            success: true,
            alreadyClaimed: true,
            licenseId: existingLicense.id
          }
        });
      }

      // Create new license
      const license = await prisma.license.create({
        data: {
          licenseTypeId: purchaseSource.licenseTypeId,
          ownerUserId: userId,
          status: LicenseStatus.ACTIVE,
          origin: LicenseOrigin.PURCHASE
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
          reason: "GAMEPASS_CLAIM"
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
