// Shows a reminder, inside opencode's own TUI, that this session is running
// in the Docker sandbox rather than the native install (a banner printed to
// the terminal before startup scrolls away once the TUI takes over the
// alt-screen buffer; this shows up inside it instead). `setup` runs once
// when the TUI loads the plugin, so calling toast.show directly here is
// enough for a one-shot startup notice.
export default {
  id: "sandbox-banner",
  setup: async (context) => {
    context.ui.toast.show({
      variant: "info",
      title: "Docker sandbox",
      message: "This is the containerized opencode, not the native install.",
      duration: 8000,
    })
  },
}
