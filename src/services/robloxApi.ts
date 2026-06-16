import axios from 'axios';

const ROBLOX_API_KEY = process.env.ROBLOX_API_KEY;
const ROBLOX_UNIVERSE_ID = process.env.ROBLOX_UNIVERSE_ID;

if (!ROBLOX_API_KEY || !ROBLOX_UNIVERSE_ID) {
  throw new Error('ROBLOX_API_KEY and ROBLOX_UNIVERSE_ID must be set in environment variables');
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

export async function checkGamepassOwnership(userId: bigint, gamepassId: bigint): Promise<boolean> {
  try {
    const response = await robloxApi.get<GamepassOwnershipResponse>(
      `/cloud/v2/universes/${ROBLOX_UNIVERSE_ID}/users/${userId}/gamepasses/${gamepassId}`
    );
    return response.status === 200;
  } catch (error) {
    if (axios.isAxiosError(error) && error.response?.status === 404) {
      return false;
    }
    throw error;
  }
}

export async function getUserGamepasses(userId: bigint): Promise<bigint[]> {
  try {
    console.log(`Fetching gamepasses for user ${userId} in universe ${ROBLOX_UNIVERSE_ID}`);
    const response = await robloxApi.get<{ data: Array<{ id: string }> }>(
      `/cloud/v2/universes/${ROBLOX_UNIVERSE_ID}/users/${userId}/game-passes`
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
