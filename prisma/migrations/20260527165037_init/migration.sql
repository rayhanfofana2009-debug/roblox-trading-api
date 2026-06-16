-- CreateEnum
CREATE TYPE "LicenseStatus" AS ENUM ('ACTIVE', 'LOCKED_IN_TRADE', 'REVOKED');

-- CreateEnum
CREATE TYPE "LicenseOrigin" AS ENUM ('PURCHASE', 'TRADE');

-- CreateEnum
CREATE TYPE "TradeStatus" AS ENUM ('PENDING', 'COMPLETED', 'CANCELLED', 'EXPIRED');

-- CreateEnum
CREATE TYPE "TradeSide" AS ENUM ('INITIATOR', 'COUNTERPARTY');

-- CreateTable
CREATE TABLE "LicenseType" (
    "id" UUID NOT NULL,
    "displayName" TEXT NOT NULL,
    "tradable" BOOLEAN NOT NULL DEFAULT true,
    "stackable" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "LicenseType_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "PurchaseSource" (
    "id" UUID NOT NULL,
    "universeId" BIGINT NOT NULL,
    "gamepassId" BIGINT NOT NULL,
    "licenseTypeId" UUID NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "PurchaseSource_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Purchase" (
    "id" UUID NOT NULL,
    "robloxReceiptId" TEXT NOT NULL,
    "buyerUserId" BIGINT NOT NULL,
    "licenseTypeId" UUID NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Purchase_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "License" (
    "id" UUID NOT NULL,
    "licenseTypeId" UUID NOT NULL,
    "ownerUserId" BIGINT NOT NULL,
    "status" "LicenseStatus" NOT NULL DEFAULT 'ACTIVE',
    "origin" "LicenseOrigin" NOT NULL,
    "createdFromPurchaseId" UUID,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "License_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Trade" (
    "id" UUID NOT NULL,
    "initiatorUserId" BIGINT NOT NULL,
    "counterpartyUserId" BIGINT NOT NULL,
    "status" "TradeStatus" NOT NULL DEFAULT 'PENDING',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "completedAt" TIMESTAMP(3),

    CONSTRAINT "Trade_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "TradeItem" (
    "id" UUID NOT NULL,
    "tradeId" UUID NOT NULL,
    "side" "TradeSide" NOT NULL,
    "licenseId" UUID NOT NULL,
    "fromUserId" BIGINT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "TradeItem_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "OwnershipEvent" (
    "id" UUID NOT NULL,
    "licenseId" UUID NOT NULL,
    "fromUserId" BIGINT,
    "toUserId" BIGINT NOT NULL,
    "reason" TEXT NOT NULL,
    "purchaseId" UUID,
    "tradeId" UUID,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "OwnershipEvent_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "PurchaseSource_licenseTypeId_idx" ON "PurchaseSource"("licenseTypeId");

-- CreateIndex
CREATE UNIQUE INDEX "PurchaseSource_universeId_gamepassId_key" ON "PurchaseSource"("universeId", "gamepassId");

-- CreateIndex
CREATE UNIQUE INDEX "Purchase_robloxReceiptId_key" ON "Purchase"("robloxReceiptId");

-- CreateIndex
CREATE INDEX "Purchase_licenseTypeId_idx" ON "Purchase"("licenseTypeId");

-- CreateIndex
CREATE UNIQUE INDEX "Purchase_buyerUserId_licenseTypeId_key" ON "Purchase"("buyerUserId", "licenseTypeId");

-- CreateIndex
CREATE UNIQUE INDEX "License_createdFromPurchaseId_key" ON "License"("createdFromPurchaseId");

-- CreateIndex
CREATE INDEX "License_ownerUserId_idx" ON "License"("ownerUserId");

-- CreateIndex
CREATE INDEX "License_licenseTypeId_ownerUserId_idx" ON "License"("licenseTypeId", "ownerUserId");

-- CreateIndex
CREATE INDEX "License_status_idx" ON "License"("status");

-- CreateIndex
CREATE INDEX "TradeItem_licenseId_idx" ON "TradeItem"("licenseId");

-- CreateIndex
CREATE UNIQUE INDEX "TradeItem_tradeId_licenseId_key" ON "TradeItem"("tradeId", "licenseId");

-- CreateIndex
CREATE INDEX "OwnershipEvent_licenseId_createdAt_idx" ON "OwnershipEvent"("licenseId", "createdAt");

-- CreateIndex
CREATE INDEX "OwnershipEvent_toUserId_createdAt_idx" ON "OwnershipEvent"("toUserId", "createdAt");

-- AddForeignKey
ALTER TABLE "PurchaseSource" ADD CONSTRAINT "PurchaseSource_licenseTypeId_fkey" FOREIGN KEY ("licenseTypeId") REFERENCES "LicenseType"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Purchase" ADD CONSTRAINT "Purchase_licenseTypeId_fkey" FOREIGN KEY ("licenseTypeId") REFERENCES "LicenseType"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "License" ADD CONSTRAINT "License_licenseTypeId_fkey" FOREIGN KEY ("licenseTypeId") REFERENCES "LicenseType"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "License" ADD CONSTRAINT "License_createdFromPurchaseId_fkey" FOREIGN KEY ("createdFromPurchaseId") REFERENCES "Purchase"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "TradeItem" ADD CONSTRAINT "TradeItem_tradeId_fkey" FOREIGN KEY ("tradeId") REFERENCES "Trade"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "TradeItem" ADD CONSTRAINT "TradeItem_licenseId_fkey" FOREIGN KEY ("licenseId") REFERENCES "License"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "OwnershipEvent" ADD CONSTRAINT "OwnershipEvent_licenseId_fkey" FOREIGN KEY ("licenseId") REFERENCES "License"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
