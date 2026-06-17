import axios from 'axios';

const ROBLOX_API_KEY = process.env.ROBLOX_API_KEY;

if (!ROBLOX_API_KEY) {
  throw new Error('ROBLOX_API_KEY must be set in environment variables');
}

const robloxApi = axios.create({
  baseURL: 'https://apis.roblox.com',
  headers: {
    'x-api-key': ROBLOX_API_KEY,
    'Content-Type': 'application/json',
  },
});

export interface GamepassOwnershipResponse {
  data: Array<{
    id: string;
    name: string;
  }>;
}

export async function checkGamepassOwnership(userId: bigint, gamepassId: bigint, universeId: bigint): Promise<boolean> {
  try {
    const response = await robloxApi.get<GamepassOwnershipResponse>(
      `/cloud/v2/universes/${universeId}/users/${userId}/gamepasses/${gamepassId}`
    );
    return response.status === 200;
  } catch (error) {
    if (axios.isAxiosError(error) && error.response?.status === 404) {
      return false;
    }
    throw error;
  }
}

export async function getUserGamepasses(userId: bigint, universeId: bigint): Promise<bigint[]> {
  try {
    console.log(`Fetching gamepasses for user ${userId} in universe ${universeId}`);
    const response = await robloxApi.get<{ data: Array<{ id: string }> }>(
      `/cloud/v2/universes/${universeId}/users/${userId}/game-passes`
    );
    console.log(`Roblox API response:`, JSON.stringify(response.data));
    return response.data.data.map((gp) => BigInt(gp.id));
  } catch (error) {
    console.error(`Error fetching gamepasses for user ${userId}:`, error);
    if (axios.isAxiosError(error)) {
      console.error(`Response status:`, error.response?.status);
      console.error(`Response data:`, error.response?.data);
    }
    if (axios.isAxiosError(error) && error.response?.status === 404) {
      return [];
    }
    throw error;
  }
}
