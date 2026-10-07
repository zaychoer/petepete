/// <reference types="vite/client" />
import * as Sentry from "@sentry/tanstackstart-react";
import { sentryOptions } from "@/lib/sentry-options";

Sentry.init(sentryOptions);

import handler, { createServerEntry } from "@tanstack/react-start/server-entry";

export default createServerEntry({
  fetch(request) {
    return handler.fetch(request);
  },
});
