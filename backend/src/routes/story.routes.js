import { Router } from "express";
import { requireAuth } from "../middleware/auth.js";
import { createStory, getFeedStories, viewStory, deleteStory } from "../controllers/story.controller.js";

const router = Router();
router.use(requireAuth);

router.post("/", createStory);
router.get("/", getFeedStories);
router.post("/:storyId/view", viewStory);
router.delete("/:storyId", deleteStory);

export default router;
