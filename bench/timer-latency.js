// Portable Node/Bun/bkr latency probe: 100 batches of 128 one-shot timers.
const samples = [];
for (let batch = 0; batch < 100; batch++) {
    await Promise.all(Array.from({ length: 128 }, () => {
        const start = performance.now();
        return new Promise((resolve) => setTimeout(() => {
            samples.push(performance.now() - start);
            resolve();
        }, 0));
    }));
}
samples.sort((a, b) => a - b);
console.log(JSON.stringify({
    min: samples[0],
    p50: samples[Math.floor(samples.length * .5)],
    p99: samples[Math.floor(samples.length * .99)],
    max: samples[samples.length - 1]
}));
