import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const generateAgoraToken = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 4: Generate Agora RTC token for voice channel
    // Channel name = sessionId, TTL = 3600s
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
