import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const sendNotification = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 4: Send push via OneSignal
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
