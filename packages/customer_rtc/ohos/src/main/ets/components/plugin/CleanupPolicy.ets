/** Native destroy is async; only its fulfilled promise confirms release. */
export class CleanupPolicy {
  private warnings: boolean = false;
  stop(action: () => number): void {
    try { if (action() !== 0) { this.warnings = true; } } catch (_) { this.warnings = true; }
  }
  async destroy(action: () => Promise<void>): Promise<string> {
    await action();
    return this.warnings ? 'releasedWithWarnings' : 'released';
  }
}
