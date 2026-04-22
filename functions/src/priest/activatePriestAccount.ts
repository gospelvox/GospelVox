import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const activatePriestAccount = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 2: After Rs.500 payment verified,
    // set priests/{uid}.isActivated = true
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
