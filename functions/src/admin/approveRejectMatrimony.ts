import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const approveRejectMatrimony = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 5: Admin approves/rejects matrimony profile
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
