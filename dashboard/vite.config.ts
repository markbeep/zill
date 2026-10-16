import { defineConfig } from 'vite';
import solid from 'vite-plugin-solid';

export default defineConfig({
  plugins: [solid()],
  build: { target: 'esnext' },
  // Worker as a plain ES module so it can be loaded without a service worker shim.
  worker: { format: 'es' },
  server: { port: 5173 },
});
