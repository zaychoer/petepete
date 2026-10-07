import { defineConfig, globalIgnores } from "eslint/config";
import tseslint from "typescript-eslint";

const eslintConfig = defineConfig([
  ...tseslint.configs.recommended,
  globalIgnores([".output/**", ".vinxi/**", ".next/**", "src/routeTree.gen.ts"]),
]);

export default eslintConfig;
