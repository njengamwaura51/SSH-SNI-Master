import { Router, type IRouter } from "express";
import healthRouter from "./health";
import releasesRouter from "./releases";

const router: IRouter = Router();

router.use(healthRouter);
router.use(releasesRouter);

export default router;
