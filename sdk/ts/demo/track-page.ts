// Stands up the tracking worker and turns its summary into the page title,
// the same channel track-prove.ts reads over the DevTools protocol.

const worker = new Worker(new URL("./track-worker.js", import.meta.url), { type: "module" });

worker.addEventListener("message", (event: MessageEvent) => {
  const data = event.data as { kind: string; summary?: Record<string, { ok: boolean }>; message?: string };
  if (data.kind === "error") {
    document.title = `GOSSTRACK FAIL ${data.message}`;
    return;
  }
  if (data.kind !== "done" || !data.summary) return;
  const summary = data.summary;
  (window as unknown as { trackSummary: unknown }).trackSummary = summary;
  const allOk = ["face", "pose", "hand", "segmentation"].every((name) => summary[name]?.ok);
  document.title = `${allOk ? "GOSSTRACK PASS" : "GOSSTRACK FAIL"} ${JSON.stringify(summary)}`;
});

worker.postMessage({ kind: "run" });
