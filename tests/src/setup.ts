/**
 * Test setup - loads environment variables from .env in parent directory
 */

import { config } from 'dotenv';
import { resolve } from 'path';

// Load .env from parent directory (project root)
config({ path: resolve(__dirname, '../../.env') });
