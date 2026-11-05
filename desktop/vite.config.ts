import { defineConfig } from "vite";

export default defineConfig({
  clearScreen: false,
  build: { outDir: "dist", target: "es2022", chunkSizeWarningLimit: 2000 },
  server: { port: 5173, strictPort: true, proxy: { "/core": "http://localhost:5174" } },
});
