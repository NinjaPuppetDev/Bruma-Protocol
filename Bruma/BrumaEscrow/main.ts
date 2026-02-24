import {
  CronCapability,
  handler,
  Runner,
} from "@chainlink/cre-sdk";
import type { Config } from "./config";
import { onSettlementCron } from "./workflows/settlement";
import { onRiskCron } from "./workflows/risk";

const initWorkflow = (config: Config) => {
  const settlementCron = new CronCapability();
  const riskCron       = new CronCapability();

  return [
    handler(
      settlementCron.trigger({ schedule: config.settlementSchedule }),
      onSettlementCron,
    ),
    handler(
      riskCron.trigger({ schedule: config.riskSchedule }),
      onRiskCron,
    ),
  ];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}