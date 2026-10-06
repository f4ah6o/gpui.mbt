'use strict';

// actrun 0.32.0's JS runner assumes POSIX absolute paths and .script files.
// On native Windows, make its cwd paths root-relative (which Windows accepts)
// and turn only its generated PowerShell step file into a .ps1 file before the
// runner invokes it. The pinned third-party CLI itself remains unmodified.
const fs = require('node:fs');
const childProcess = require('node:child_process');

const nativeCwd = process.cwd.bind(process);
process.cwd = () => {
  const cwd = nativeCwd();
  const drivePath = /^([A-Za-z]):[\\/](.*)$/.exec(cwd);
  return drivePath ? `/${drivePath[2].replace(/\\/g, '/')}` : cwd;
};

const nativeSpawnSync = childProcess.spawnSync.bind(childProcess);
childProcess.spawnSync = (command, args, options) => {
  if (command === 'env' && Array.isArray(args)) {
    const commandIndex = args.indexOf('-Command');
    const shellIndex = args.findIndex((arg) => /^pwsh(?:\.exe)?$/i.test(arg));
    const commandText = commandIndex >= 0 ? args[commandIndex + 1] : undefined;
    const scriptMatch = typeof commandText === 'string'
      ? /^\.\s+'((?:[^']|'')+\.script)'$/.exec(commandText)
      : undefined;
    if (shellIndex >= 0 && shellIndex < commandIndex && scriptMatch) {
      const scriptPath = scriptMatch[1].replace(/''/g, "'");
      const powershellPath = scriptPath.replace(/\.script$/i, '.ps1');
      fs.copyFileSync(scriptPath, powershellPath);
      const quotedPath = powershellPath.replace(/'/g, "''");
      const patchedArgs = args.slice();
      patchedArgs[commandIndex + 1] = `. '${quotedPath}'`;
      return nativeSpawnSync(command, patchedArgs, options);
    }
  }
  return nativeSpawnSync(command, args, options);
};
