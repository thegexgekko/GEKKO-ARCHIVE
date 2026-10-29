import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';

// Tauri/Rust produit des DLL temporaires dans target/ pendant la compilation.
// Vite ne doit pas surveiller ces fichiers, car Windows peut les verrouiller (EBUSY).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      ignored: ['**/src-tauri/target/**'],
    },
  },
  clearScreen: false,
});
