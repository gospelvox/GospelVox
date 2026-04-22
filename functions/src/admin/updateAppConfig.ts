import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

export const updateAppConfig = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 1 Day 5: Admin updates app_config/settings
    // 1. Verify caller is admin
    // 2. Validate all fields are correct types
    // 3. Write to app_config/settings
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
