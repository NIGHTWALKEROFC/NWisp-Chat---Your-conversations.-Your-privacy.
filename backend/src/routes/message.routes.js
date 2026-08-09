import { Router } from "express";
import { requireAuth } from "../middleware/auth.js";
import { getMessages, markDelivered, markRead } from "../controllers/message.controller.js";

const router = Router();
router.use(requireAuth);

router.get("/:conversationId", getMessages);
router.post("/:messageId/delivered", markDelivered);
router.post("/:messageId/read", markRead);

export default router;
