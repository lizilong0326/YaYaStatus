#!/usr/bin/env node

import { main } from '../src/cli.mjs';

main(process.argv.slice(2)).catch((error) => {
  console.error(`doubao: ${error.message}`);
  process.exitCode = 1;
});
