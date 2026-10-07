/// <reference types="vite/client" />
import * as Sentry from "@sentry/tanstackstart-react";
import { sentryOptions } from "@/lib/sentry-options";

Sentry.init(sentryOptions);

import { StartClient } from "@tanstack/react-start/client";
import { hydrateRoot } from "react-dom/client";

hydrateRoot(document, <StartClient />);
