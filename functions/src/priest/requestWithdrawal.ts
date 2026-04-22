import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const requestWithdrawal = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 4: Priest requests withdrawal
    // Check min Rs.500, deduct from walletBalance,
    // create withdrawal doc with status "pending"
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
