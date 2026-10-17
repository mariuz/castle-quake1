# Agent Handover Guide (`castle-quake1` & `castle-engine` Vulkan Renderer)

When working on the Castle Game Engine Vulkan RHI renderer from this workspace:

- **Primary Engine Repository**: [`e:\Work\castle-engine`](file:///e:/Work/castle-engine) (WSL: `/mnt/e/Work/castle-engine`, branch: `vulkan-renderer`)
- **Full Agent Engineering & Handover Guide**: See [`e:\Work\castle-engine\AGENTS.md`](file:///e:/Work/castle-engine/AGENTS.md)
- **Master Vulkan Roadmap & Status**: See [`e:\Work\castle-engine\PLAN.md`](file:///e:/Work/castle-engine/PLAN.md)

## Quick Summary for the Next Agent
1. **Git Remote Policy**: In `e:\Work\castle-engine`, always push **only** to `origin vulkan-renderer` (`https://github.com/mariuz/castle-engine.git`), never `upstream`.
2. **Current Progress**: Phases 1–5 are complete; Phase 6 items **6.1** (`TVulkanDescriptorPoolAllocator`) and **6.2** (`TCastleVulkanStagingUploader`) are complete and verified with **43/43** passing unit tests in `TTestCastleVulkanRHI`.
3. **Next Task**: **6.3. Bindless Texture & Sampler Indexing (`VK_EXT_descriptor_indexing` / Vulkan 1.2 Core)** in [`e:\Work\castle-engine\PLAN.md`](file:///e:/Work/castle-engine/PLAN.md#L202-L204).
