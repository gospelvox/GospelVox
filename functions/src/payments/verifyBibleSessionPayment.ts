import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const verifyBibleSessionPayment = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 5: Verify Bible session payment, return Meet link
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
