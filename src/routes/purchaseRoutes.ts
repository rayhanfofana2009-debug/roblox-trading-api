import { FastifyInstance } from "fastify";
import { prisma } from "../db.js";
import { LicenseOrigin, LicenseStatus } from "@prisma/client";
import { z } from "zod";

const verifyPurchaseBody = z.object({
  robloxReceiptId: z.string().min(1),
  buyerUserId: z.coerce.bigint(),
  universeId: z.coerce.bigint(),
  gamepassId: z.coerce.bigint()
});

const createPurchaseSourceBody = z.object({
  universeId: z.coerce.bigint(),
  gamepassId: z.coerce.bigint(),
  licenseTypeId: z.string().uuid(),
  displayName: z.string().min(1)
});

export async function registerPurchaseRoutes(app: FastifyInstance) {
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

  app.get("/v1/purchase-sources", async (request, reply) => {
    const purchaseSources = await prisma.purchaseSource.findMany({
      include: { licenseType: true }
    });

    return reply.send({
      data: purchaseSources.map(ps => ({
        id: ps.id,
        universeId: ps.universeId.toString(),
        gamepassId: ps.gamepassId.toString(),
        licenseTypeId: ps.licenseTypeId,
        displayName: ps.licenseType.displayName
      }))
    });
  });

  app.delete("/v1/purchase-sources/:id", async (request, reply) => {
    const { id } = request.params as { id: string };

    await prisma.purchaseSource.delete({
      where: { id }
    });

    return reply.code(204).send();
  });

  app.post("/v1/purchase-sources", async (request, reply) => {
    const parsed = createPurchaseSourceBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.badRequest("Invalid request body.");
    }

    const { universeId, gamepassId, licenseTypeId, displayName } = parsed.data;

    // Check if license type exists, create if not
    let licenseType = await prisma.licenseType.findUnique({
      where: { id: licenseTypeId }
    });

    if (!licenseType) {
      licenseType = await prisma.licenseType.create({
        data: {
          id: licenseTypeId,
          displayName,
          tradable: true,
          stackable: false
        }
      });
    }

    // Check if purchase source already exists
    const existing = await prisma.purchaseSource.findUnique({
      where: {
        universeId_gamepassId: { universeId, gamepassId }
      }
    });

    if (existing) {
      return reply.conflict("Purchase source already exists for this universe/gamepass.");
    }

    // Create purchase source
    const purchaseSource = await prisma.purchaseSource.create({
      data: {
        universeId,
        gamepassId,
        licenseTypeId
      },
      include: {
        licenseType: true
      }
    });

    return reply.code(201).send({
      data: {
        id: purchaseSource.id,
        universeId: purchaseSource.universeId.toString(),
        gamepassId: purchaseSource.gamepassId.toString(),
        licenseTypeId: purchaseSource.licenseTypeId,
        displayName: purchaseSource.licenseType.displayName
      }
    });
  });
}
