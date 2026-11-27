import { window } from '@kit.ArkUI';

// System bar colors belong to the main window. The full-screen layout belongs
// to the window containing the presenter, which can be a separate subwindow.
class WindowSetting<T> {
  target?: window.Window;
  private original?: T;
  private applied: boolean = false;
  private readonly read: (w: window.Window) => T;
  private readonly write: (w: window.Window, value: T) => Promise<void>;
  private readonly fullValue: T;

  constructor(read: (w: window.Window) => T,
    write: (w: window.Window, value: T) => Promise<void>, fullValue: T) {
    this.read = read;
    this.write = write;
    this.fullValue = fullValue;
  }

  async set(target?: window.Window): Promise<void> {
    if (this.target && this.target !== target) {
      const old = this.target;
      this.applied = false;
      if (this.original !== undefined && this.original !== this.fullValue) {
        try { await this.write(old, this.original); }
        catch (_) {
          // A destroyed window has nothing to restore. Keep a live window's
          // original value for retry after a transient window service failure.
          let destroyed = false;
          try { old.getWindowProperties(); } catch (_) { destroyed = true; }
          if (!destroyed) { throw new Error('Unable to restore host window settings'); }
        }
      }
      this.target = undefined;
      this.original = undefined;
      this.applied = false;
    }
    if (!target || this.applied) { return; }
    if (!this.target) {
      this.original = this.read(target);
      this.target = target;
    }
    if (this.original !== this.fullValue) { await this.write(target, this.fullValue); }
    this.applied = true;
  }
}

export class CallWindowBars {
  private colors = new WindowSetting<window.SystemBarProperties>(
    (w: window.Window) => w.getWindowSystemBarProperties(),
    (w: window.Window, colors: window.SystemBarProperties) => w.setWindowSystemBarProperties(colors),
    { statusBarColor: '#00000000', navigationBarColor: '#00000000',
      statusBarContentColor: '#FFFFFFFF', navigationBarContentColor: '#FFFFFFFF' });
  private layout = new WindowSetting<boolean>(
    (w: window.Window) => w.getWindowProperties().isLayoutFullScreen,
    (w: window.Window, full: boolean) => w.setWindowLayoutFullScreen(full), true);
  private main?: window.Window;
  private presenter?: window.Window;
  private pending: Promise<void> = Promise.resolve();

  show(main?: window.Window, presenter: window.Window | undefined = main): Promise<void> {
    this.main = main;
    this.presenter = presenter;
    this.pending = this.pending.then(() => this.apply()).catch(() => this.apply()).catch(() => {});
    return this.pending;
  }

  private async apply(): Promise<void> {
    const main = this.main, presenter = this.presenter;
    if (main !== this.colors.target) {
      try { await this.colors.set(undefined); }
      finally { await this.layout.set(presenter); }
    } else {
      await this.layout.set(presenter);
    }
    if (main === this.main) { await this.colors.set(main); }
  }
}
