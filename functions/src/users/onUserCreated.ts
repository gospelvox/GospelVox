import {onDocumentCreated} from "firebase-functions/v2/firestore";
import {REGION} from "../config/constants";

export const onUserCreated = onDocumentCreated(
  {document: "users/{userId}", region: REGION},
  async (event) => {
    // TODO: Send welcome notification, log analytics event
    const userId = event.params.userId;
    console.log(`New user created: ${userId}`);
  }
);
