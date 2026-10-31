// node test-motor.js — tarda ~25 s y sí toca el escritorio: comprueba que
// matar el PowerShell no se lleva puesto al servidor y que vuelve solo.
// Mata el PowerShell a mano y comprueba que el servidor sigue de pie.
process.env.PORT = "7073";
const assert = require("assert");
const { execSync } = require("child_process");
const s = require("./server.js");
const H = { "x-token": s.TOKEN };
const esperar = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  await esperar(9000);
  const antes = await fetch("http://127.0.0.1:7073/state", { headers: H });
  assert.equal(antes.status, 200, "el estado anda antes de matar nada");

  const pid = execSync(
    `powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \\"Name='powershell.exe'\\" | Where-Object { $_.CommandLine -like '*helper.ps1*' } | Select-Object -First 1).ProcessId"`
  ).toString().trim();
  console.log("mato el motor, pid", pid);
  execSync(`powershell -NoProfile -Command "Stop-Process -Id ${pid} -Force"`);

  await esperar(1500);
  const r1 = await fetch("http://127.0.0.1:7073/", { method: "GET" });
  assert.equal(r1.status, 200, "el servidor sigue sirviendo la página con el motor caído");
  await fetch("http://127.0.0.1:7073/do", { method: "POST", headers: H, body: "click" });
  console.log("el servidor sobrevivió al motor muerto");

  await esperar(12000);
  const r2 = await fetch("http://127.0.0.1:7073/state", { headers: H });
  assert.equal(r2.status, 200, "el motor volvió solo y el estado anda de nuevo");
  const j = await r2.json();
  assert.ok(j.host, "y contesta datos de verdad: " + j.host);
  console.log("el motor volvió solo:", j.host, "| vol", j.volume);
  s.server.close();
  process.exit(0);
})();
