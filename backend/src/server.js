import express from "express";
import http from "http";
import { Server } from "socket.io";
import helmet from "helmet";
import cors from "cors";
import compression from "compression";
import morgan from "morgan";
import dotenv from "dotenv";

import authRoutes from "./routes/auth.routes.js";
import messageRoutes from "./routes/message.routes.js";
import storyRoutes from "./routes/story.routes.js";
import { generalLimiter } from "./middleware/rateLimit.js";
import { initChatSocket } from "./sockets/chat.socket.js";
import { startCleanupJob } from "./jobs/cleanup.job.js";

dotenv.config();

const app = express();
const server = http.createServer(app);

const allowedOrigins = (process.env.ALLOWED_ORIGINS || "").split(",").filter(Boolean);

app.use(helmet());
app.use(compression());
app.use(morgan("combined"));
app.use(cors({ origin: allowedOrigins.length ? allowedOrigins : false, credentials: true }));
app.use(express.json({ limit: "1mb" }));
app.use(generalLimiter);

app.get("/health", (req, res) => res.json({ ok: true }));
app.use("/api/auth", authRoutes);
app.use("/api/messages", messageRoutes);
app.use("/api/stories", storyRoutes);

const io = new Server(server, {
  cors: { origin: allowedOrigins.length ? allowedOrigins : false },
});
initChatSocket(io);
startCleanupJob();

const PORT = process.env.PORT || 8080;
server.listen(PORT, () => console.log(`Server listening on ${PORT}`));
