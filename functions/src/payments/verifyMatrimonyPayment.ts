import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const verifyMatrimonyPayment = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 5: Verify listing/unlock/chat tier payment
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
