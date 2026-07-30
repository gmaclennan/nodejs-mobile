'use strict';

// Tier 1 on-device smoke (see docs/TESTING.md on the patches branch): prove
// the cross-compiled mobile libnode boots and runs JavaScript on the device
// runtime, then exits cleanly. The marker string is grepped by the smoke
// workflows — keep in sync.
console.log(
  `NODEJS_MOBILE_SMOKE_OK ${process.version} ${process.platform} ${process.arch}`,
);
process.exit(0);
