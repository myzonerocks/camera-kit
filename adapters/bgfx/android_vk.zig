//! The zero-copy camera import for the Vulkan backend. The adapter owns the
//! instance and device, hands the device to the renderer, and runs a
//! compute pass on its own queue converting each camera hardware buffer to
//! an rgba image the renderer samples as an external texture. Camera pixels
//! never touch the cpu; the one conversion is a counted gpu pass.
//!
//! Contracts this file is written against, verified in the vendored source:
//! the renderer adopts an external device from the platform data and takes
//! queue zero of the graphics and compute family; external textures are
//! transitioned to the general layout at every frame boundary; a host fence
//! wait before the next queue submission makes the conversion's writes
//! visible to it. Hardware buffers arrive from the foreign queue family and
//! are acquired and released with ownership transfer barriers.

const std = @import("std");
const blob = @import("blob.zig");
const blobs = @import("shader_blobs");

const c = @cImport({
    @cDefine("VK_USE_PLATFORM_ANDROID_KHR", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("android/hardware_buffer.h");
});

comptime {
    _ = &Context.init;
    _ = &Context.deinit;
    _ = &Context.rendererDevice;
    _ = &Converter.init;
    _ = &Converter.deinit;
    _ = &Converter.setConversion;
    _ = &Converter.convert;
    _ = &Converter.targetImage;
}

pub const Error = error{
    VulkanFailure,
    NoUsableGpu,
    SingleQueue,
    UnsupportedFormat,
    ShaderRejected,
};

fn check(result: c.VkResult) Error!void {
    if (result != c.VK_SUCCESS) return error.VulkanFailure;
}

/// Ring depth covers the renderer's maximum frames in flight plus the one
/// being converted, so a target is never rewritten while the renderer may
/// still sample it.
pub const ring_depth = 4;

const device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
    "VK_ANDROID_external_memory_android_hardware_buffer",
    "VK_EXT_queue_family_foreign",
};

pub const Context = struct {
    instance: c.VkInstance,
    physical: c.VkPhysicalDevice,
    device: c.VkDevice,
    family: u32,
    convert_queue: c.VkQueue,
    memory_properties: c.VkPhysicalDeviceMemoryProperties,

    pub fn init() Error!Context {
        var app_info: c.VkApplicationInfo = std.mem.zeroes(c.VkApplicationInfo);
        app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.apiVersion = c.VK_API_VERSION_1_1;
        var instance_info: c.VkInstanceCreateInfo = std.mem.zeroes(c.VkInstanceCreateInfo);
        instance_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        instance_info.pApplicationInfo = &app_info;
        var instance: c.VkInstance = null;
        try check(c.vkCreateInstance(&instance_info, null, &instance));
        errdefer c.vkDestroyInstance(instance, null);

        var device_count: u32 = 1;
        var physical: c.VkPhysicalDevice = null;
        const enum_result = c.vkEnumeratePhysicalDevices(instance, &device_count, &physical);
        if ((enum_result != c.VK_SUCCESS and enum_result != c.VK_INCOMPLETE) or device_count == 0) {
            return error.NoUsableGpu;
        }

        // The renderer selects queue zero of the first family carrying
        // graphics and compute; the conversion queue is queue one of the
        // same family, so both live on the one device.
        var family_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
        var families: [16]c.VkQueueFamilyProperties = undefined;
        family_count = @min(family_count, families.len);
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, &families);
        const wanted = c.VK_QUEUE_GRAPHICS_BIT | c.VK_QUEUE_COMPUTE_BIT;
        var family: u32 = std.math.maxInt(u32);
        for (families[0..family_count], 0..) |properties, index| {
            if (properties.queueFlags & wanted == wanted) {
                family = @intCast(index);
                if (properties.queueCount < 2) return error.SingleQueue;
                break;
            }
        }
        if (family == std.math.maxInt(u32)) return error.NoUsableGpu;

        var ycbcr: c.VkPhysicalDeviceSamplerYcbcrConversionFeatures = std.mem.zeroes(c.VkPhysicalDeviceSamplerYcbcrConversionFeatures);
        ycbcr.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
        ycbcr.samplerYcbcrConversion = c.VK_TRUE;
        var features: c.VkPhysicalDeviceFeatures2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
        features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        features.pNext = &ycbcr;

        const priorities = [2]f32{ 1.0, 1.0 };
        var queue_info: c.VkDeviceQueueCreateInfo = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = family;
        queue_info.queueCount = 2;
        queue_info.pQueuePriorities = &priorities;

        var device_info: c.VkDeviceCreateInfo = std.mem.zeroes(c.VkDeviceCreateInfo);
        device_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_info.pNext = &features;
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos = &queue_info;
        device_info.enabledExtensionCount = device_extensions.len;
        device_info.ppEnabledExtensionNames = @ptrCast(&device_extensions);
        var device: c.VkDevice = null;
        try check(c.vkCreateDevice(physical, &device_info, null, &device));

        var convert_queue: c.VkQueue = null;
        c.vkGetDeviceQueue(device, family, 1, &convert_queue);
        var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(physical, &memory_properties);

        return .{
            .instance = instance,
            .physical = physical,
            .device = device,
            .family = family,
            .convert_queue = convert_queue,
            .memory_properties = memory_properties,
        };
    }

    /// Handed to the renderer as its device. The renderer must shut down
    /// before this context is deinitialized.
    pub fn rendererDevice(ctx: *const Context) ?*anyopaque {
        return ctx.device;
    }

    pub fn deinit(ctx: *Context) void {
        c.vkDestroyDevice(ctx.device, null);
        c.vkDestroyInstance(ctx.instance, null);
        ctx.* = undefined;
    }

    fn memoryTypeIndex(ctx: *const Context, type_bits: u32, wanted_flags: c.VkMemoryPropertyFlags) Error!u32 {
        for (0..ctx.memory_properties.memoryTypeCount) |index| {
            const bit = @as(u32, 1) << @intCast(index);
            if (type_bits & bit != 0 and
                ctx.memory_properties.memoryTypes[index].propertyFlags & wanted_flags == wanted_flags)
            {
                return @intCast(index);
            }
        }
        return error.VulkanFailure;
    }
};

const AhbImport = struct {
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view_y: c.VkImageView = null,
    view_uv: c.VkImageView = null,

    fn deinit(import: *AhbImport, device: c.VkDevice) void {
        if (import.view_uv != null) c.vkDestroyImageView(device, import.view_uv, null);
        if (import.view_y != null) c.vkDestroyImageView(device, import.view_y, null);
        if (import.image != null) c.vkDestroyImage(device, import.image, null);
        if (import.memory != null) c.vkFreeMemory(device, import.memory, null);
        import.* = .{};
    }
};

const Target = struct {
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    initialized: bool = false,

    fn deinit(target: *Target, device: c.VkDevice) void {
        if (target.view != null) c.vkDestroyImageView(device, target.view, null);
        if (target.image != null) c.vkDestroyImage(device, target.image, null);
        if (target.memory != null) c.vkFreeMemory(device, target.memory, null);
        target.* = .{};
    }
};

pub const Converter = struct {
    ctx: Context,
    module: c.VkShaderModule,
    set_layout: c.VkDescriptorSetLayout,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    sampler: c.VkSampler,
    descriptor_pool: c.VkDescriptorPool,
    sets: [ring_depth]c.VkDescriptorSet,
    ubo: c.VkBuffer,
    ubo_memory: c.VkDeviceMemory,
    ubo_mapped: [*]f32,
    command_pool: c.VkCommandPool,
    commands: [ring_depth]c.VkCommandBuffer,
    fences: [ring_depth]c.VkFence,
    imports: [ring_depth]AhbImport,
    targets: [ring_depth]Target,
    width: u32 = 0,
    height: u32 = 0,
    slot: u32 = 0,
    converted_frames: u64 = 0,

    pub fn init(ctx: Context) Error!Converter {
        const parsed = blob.parse(blobs.cs_nv12_to_rgba_spirv) catch return error.ShaderRejected;
        if (parsed.kind != 'C') return error.ShaderRejected;
        // The pipeline layout below encodes the compiler's binding
        // convention; every binding is asserted against the payload's own
        // declarations so a convention change fails at startup.
        for ([_]u32{ 0, 2, 3, 4, 18, 19 }) |binding| {
            if (!blob.spirvDeclaresBinding(parsed.payload, binding)) return error.ShaderRejected;
        }

        const device = ctx.device;
        var module_info: c.VkShaderModuleCreateInfo = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        module_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        module_info.codeSize = parsed.payload.len;
        module_info.pCode = @ptrCast(@alignCast(parsed.payload.ptr));
        var module: c.VkShaderModule = null;
        try check(c.vkCreateShaderModule(device, &module_info, null, &module));
        errdefer c.vkDestroyShaderModule(device, module, null);

        var sampler_info: c.VkSamplerCreateInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        var sampler: c.VkSampler = null;
        try check(c.vkCreateSampler(device, &sampler_info, null, &sampler));
        errdefer c.vkDestroySampler(device, sampler, null);

        const binding_infos = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 18, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = &sampler },
            .{ .binding = 19, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = &sampler },
        };
        var layout_info: c.VkDescriptorSetLayoutCreateInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = binding_infos.len;
        layout_info.pBindings = &binding_infos;
        var set_layout: c.VkDescriptorSetLayout = null;
        try check(c.vkCreateDescriptorSetLayout(device, &layout_info, null, &set_layout));
        errdefer c.vkDestroyDescriptorSetLayout(device, set_layout, null);

        var pipeline_layout_info: c.VkPipelineLayoutCreateInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &set_layout;
        var pipeline_layout: c.VkPipelineLayout = null;
        try check(c.vkCreatePipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout));
        errdefer c.vkDestroyPipelineLayout(device, pipeline_layout, null);

        var pipeline_info: c.VkComputePipelineCreateInfo = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pipeline_info.stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        pipeline_info.stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        pipeline_info.stage.module = module;
        pipeline_info.stage.pName = "main";
        pipeline_info.layout = pipeline_layout;
        var pipeline: c.VkPipeline = null;
        try check(c.vkCreateComputePipelines(device, null, 1, &pipeline_info, null, &pipeline));
        errdefer c.vkDestroyPipeline(device, pipeline, null);

        var buffer_info: c.VkBufferCreateInfo = std.mem.zeroes(c.VkBufferCreateInfo);
        buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buffer_info.size = 64;
        buffer_info.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        var ubo: c.VkBuffer = null;
        try check(c.vkCreateBuffer(device, &buffer_info, null, &ubo));
        errdefer c.vkDestroyBuffer(device, ubo, null);
        var buffer_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(device, ubo, &buffer_requirements);
        var ubo_alloc: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
        ubo_alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ubo_alloc.allocationSize = buffer_requirements.size;
        ubo_alloc.memoryTypeIndex = try ctx.memoryTypeIndex(buffer_requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        var ubo_memory: c.VkDeviceMemory = null;
        try check(c.vkAllocateMemory(device, &ubo_alloc, null, &ubo_memory));
        errdefer c.vkFreeMemory(device, ubo_memory, null);
        try check(c.vkBindBufferMemory(device, ubo, ubo_memory, 0));
        var mapped: ?*anyopaque = null;
        try check(c.vkMapMemory(device, ubo_memory, 0, 64, 0, &mapped));

        const pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = ring_depth },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = ring_depth * 2 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = ring_depth },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = ring_depth * 2 },
        };
        var pool_info: c.VkDescriptorPoolCreateInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = ring_depth;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        var descriptor_pool: c.VkDescriptorPool = null;
        try check(c.vkCreateDescriptorPool(device, &pool_info, null, &descriptor_pool));
        errdefer c.vkDestroyDescriptorPool(device, descriptor_pool, null);

        var set_layouts: [ring_depth]c.VkDescriptorSetLayout = @splat(set_layout);
        var set_alloc: c.VkDescriptorSetAllocateInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        set_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        set_alloc.descriptorPool = descriptor_pool;
        set_alloc.descriptorSetCount = ring_depth;
        set_alloc.pSetLayouts = &set_layouts;
        var sets: [ring_depth]c.VkDescriptorSet = undefined;
        try check(c.vkAllocateDescriptorSets(device, &set_alloc, &sets));

        var command_pool_info: c.VkCommandPoolCreateInfo = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        command_pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        command_pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        command_pool_info.queueFamilyIndex = ctx.family;
        var command_pool: c.VkCommandPool = null;
        try check(c.vkCreateCommandPool(device, &command_pool_info, null, &command_pool));
        errdefer c.vkDestroyCommandPool(device, command_pool, null);

        var command_alloc: c.VkCommandBufferAllocateInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        command_alloc.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        command_alloc.commandPool = command_pool;
        command_alloc.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        command_alloc.commandBufferCount = ring_depth;
        var commands: [ring_depth]c.VkCommandBuffer = undefined;
        try check(c.vkAllocateCommandBuffers(device, &command_alloc, &commands));

        var fences: [ring_depth]c.VkFence = undefined;
        var fence_info: c.VkFenceCreateInfo = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        for (&fences) |*fence| {
            try check(c.vkCreateFence(device, &fence_info, null, fence));
        }

        var ubo_words: [*]f32 = @ptrCast(@alignCast(mapped.?));
        // Identity until the first stream configuration arrives.
        for (0..16) |index| ubo_words[index] = if (index % 5 == 0) 1.0 else 0.0;

        return .{
            .ctx = ctx,
            .module = module,
            .set_layout = set_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .sampler = sampler,
            .descriptor_pool = descriptor_pool,
            .sets = sets,
            .ubo = ubo,
            .ubo_memory = ubo_memory,
            .ubo_mapped = ubo_words,
            .command_pool = command_pool,
            .commands = commands,
            .fences = fences,
            .imports = @splat(.{}),
            .targets = @splat(.{}),
        };
    }

    pub fn deinit(converter: *Converter) void {
        const device = converter.ctx.device;
        _ = c.vkDeviceWaitIdle(device);
        for (&converter.imports) |*import| import.deinit(device);
        for (&converter.targets) |*target| target.deinit(device);
        for (converter.fences) |fence| c.vkDestroyFence(device, fence, null);
        c.vkDestroyCommandPool(device, converter.command_pool, null);
        c.vkDestroyDescriptorPool(device, converter.descriptor_pool, null);
        c.vkUnmapMemory(device, converter.ubo_memory);
        c.vkFreeMemory(device, converter.ubo_memory, null);
        c.vkDestroyBuffer(device, converter.ubo, null);
        c.vkDestroyPipeline(device, converter.pipeline, null);
        c.vkDestroyPipelineLayout(device, converter.pipeline_layout, null);
        c.vkDestroyDescriptorSetLayout(device, converter.set_layout, null);
        c.vkDestroySampler(device, converter.sampler, null);
        c.vkDestroyShaderModule(device, converter.module, null);
        converter.* = undefined;
    }

    /// Column-major homogeneous conversion matrix, straight from the core's
    /// color math. Applies to frames converted after the call.
    pub fn setConversion(converter: *Converter, matrix: [16]f32) void {
        @memcpy(converter.ubo_mapped[0..16], &matrix);
    }

    /// The stable target image for a ring slot, for the renderer's external
    /// texture registration. Valid after the first convert at a given size.
    pub fn targetImage(converter: *const Converter, slot: u32) u64 {
        return @intFromPtr(converter.targets[slot].image);
    }

    /// Converts one camera hardware buffer and returns the ring slot whose
    /// target now holds the rgba frame. Blocks until the pass completes,
    /// which orders it before the renderer's next submission.
    pub fn convert(converter: *Converter, hardware_buffer: *c.AHardwareBuffer, width: u32, height: u32) Error!u32 {
        const device = converter.ctx.device;
        const slot = converter.slot;
        converter.slot = (slot + 1) % ring_depth;

        try check(c.vkWaitForFences(device, 1, &converter.fences[slot], c.VK_TRUE, std.math.maxInt(u64)));
        try check(c.vkResetFences(device, 1, &converter.fences[slot]));
        converter.imports[slot].deinit(device);

        if (width != converter.width or height != converter.height) {
            try converter.recreateTargets(width, height);
        }

        const import = try converter.importBuffer(hardware_buffer, width, height);
        converter.imports[slot] = import;
        converter.updateSet(slot, import);
        try converter.record(slot, import, width, height);

        var submit: c.VkSubmitInfo = std.mem.zeroes(c.VkSubmitInfo);
        submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &converter.commands[slot];
        try check(c.vkQueueSubmit(converter.ctx.convert_queue, 1, &submit, converter.fences[slot]));
        try check(c.vkWaitForFences(device, 1, &converter.fences[slot], c.VK_TRUE, std.math.maxInt(u64)));

        converter.converted_frames += 1;
        return slot;
    }

    fn recreateTargets(converter: *Converter, width: u32, height: u32) Error!void {
        const device = converter.ctx.device;
        _ = c.vkDeviceWaitIdle(device);
        for (&converter.targets) |*target| {
            target.deinit(device);
            var image_info: c.VkImageCreateInfo = std.mem.zeroes(c.VkImageCreateInfo);
            image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            image_info.imageType = c.VK_IMAGE_TYPE_2D;
            image_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
            image_info.extent = .{ .width = width, .height = height, .depth = 1 };
            image_info.mipLevels = 1;
            image_info.arrayLayers = 1;
            image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
            image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
            image_info.usage = c.VK_IMAGE_USAGE_STORAGE_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
            image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            try check(c.vkCreateImage(device, &image_info, null, &target.image));

            var requirements: c.VkMemoryRequirements = undefined;
            c.vkGetImageMemoryRequirements(device, target.image, &requirements);
            var alloc: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
            alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            alloc.allocationSize = requirements.size;
            alloc.memoryTypeIndex = try converter.ctx.memoryTypeIndex(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            try check(c.vkAllocateMemory(device, &alloc, null, &target.memory));
            try check(c.vkBindImageMemory(device, target.image, target.memory, 0));

            var view_info: c.VkImageViewCreateInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = target.image;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            try check(c.vkCreateImageView(device, &view_info, null, &target.view));
            target.initialized = false;
        }
        converter.width = width;
        converter.height = height;
    }

    fn importBuffer(converter: *Converter, hardware_buffer: *c.AHardwareBuffer, width: u32, height: u32) Error!AhbImport {
        const device = converter.ctx.device;
        var format_properties: c.VkAndroidHardwareBufferFormatPropertiesANDROID = std.mem.zeroes(c.VkAndroidHardwareBufferFormatPropertiesANDROID);
        format_properties.sType = c.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;
        var properties: c.VkAndroidHardwareBufferPropertiesANDROID = std.mem.zeroes(c.VkAndroidHardwareBufferPropertiesANDROID);
        properties.sType = c.VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
        properties.pNext = &format_properties;
        try check(c.vkGetAndroidHardwareBufferPropertiesANDROID(device, hardware_buffer, &properties));
        // Implementation-private formats need the ycbcr sampler route; the
        // caller counts those frames onto the declared copy path instead.
        if (format_properties.format != c.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM) return error.UnsupportedFormat;

        var import: AhbImport = .{};
        errdefer import.deinit(device);

        var external_info: c.VkExternalMemoryImageCreateInfo = std.mem.zeroes(c.VkExternalMemoryImageCreateInfo);
        external_info.sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
        external_info.handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;
        var image_info: c.VkImageCreateInfo = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.pNext = &external_info;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.format = format_properties.format;
        image_info.extent = .{ .width = width, .height = height, .depth = 1 };
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = c.VK_IMAGE_USAGE_SAMPLED_BIT;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try check(c.vkCreateImage(device, &image_info, null, &import.image));

        var dedicated: c.VkMemoryDedicatedAllocateInfo = std.mem.zeroes(c.VkMemoryDedicatedAllocateInfo);
        dedicated.sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
        dedicated.image = import.image;
        var import_info: c.VkImportAndroidHardwareBufferInfoANDROID = std.mem.zeroes(c.VkImportAndroidHardwareBufferInfoANDROID);
        import_info.sType = c.VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID;
        import_info.pNext = &dedicated;
        import_info.buffer = hardware_buffer;
        var alloc: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc.pNext = &import_info;
        alloc.allocationSize = properties.allocationSize;
        alloc.memoryTypeIndex = try converter.ctx.memoryTypeIndex(properties.memoryTypeBits, 0);
        try check(c.vkAllocateMemory(device, &alloc, null, &import.memory));
        try check(c.vkBindImageMemory(device, import.image, import.memory, 0));

        var view_info: c.VkImageViewCreateInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = import.image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8_UNORM;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_PLANE_0_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try check(c.vkCreateImageView(device, &view_info, null, &import.view_y));
        view_info.format = c.VK_FORMAT_R8G8_UNORM;
        view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_PLANE_1_BIT;
        try check(c.vkCreateImageView(device, &view_info, null, &import.view_uv));
        return import;
    }

    fn updateSet(converter: *Converter, slot: u32, import: AhbImport) void {
        const y_info: c.VkDescriptorImageInfo = .{ .sampler = null, .imageView = import.view_y, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        const uv_info: c.VkDescriptorImageInfo = .{ .sampler = null, .imageView = import.view_uv, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        const target_info: c.VkDescriptorImageInfo = .{ .sampler = null, .imageView = converter.targets[slot].view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
        const ubo_info: c.VkDescriptorBufferInfo = .{ .buffer = converter.ubo, .offset = 0, .range = 64 };
        const writes = [_]c.VkWriteDescriptorSet{
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = converter.sets[slot], .dstBinding = 0, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pImageInfo = null, .pBufferInfo = &ubo_info, .pTexelBufferView = null },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = converter.sets[slot], .dstBinding = 2, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &y_info, .pBufferInfo = null, .pTexelBufferView = null },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = converter.sets[slot], .dstBinding = 3, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &uv_info, .pBufferInfo = null, .pTexelBufferView = null },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = converter.sets[slot], .dstBinding = 4, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &target_info, .pBufferInfo = null, .pTexelBufferView = null },
        };
        c.vkUpdateDescriptorSets(converter.ctx.device, writes.len, &writes, 0, null);
    }

    fn record(converter: *Converter, slot: u32, import: AhbImport, width: u32, height: u32) Error!void {
        const command = converter.commands[slot];
        var begin: c.VkCommandBufferBeginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(c.vkBeginCommandBuffer(command, &begin));

        // Acquire the camera buffer from the foreign family and put the
        // target into the general layout the renderer tracks.
        var acquire: c.VkImageMemoryBarrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        acquire.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        acquire.srcAccessMask = 0;
        acquire.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        acquire.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        acquire.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        acquire.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT;
        acquire.dstQueueFamilyIndex = converter.ctx.family;
        acquire.image = import.image;
        acquire.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        var target_barrier: c.VkImageMemoryBarrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        target_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        target_barrier.srcAccessMask = 0;
        target_barrier.dstAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        target_barrier.oldLayout = if (converter.targets[slot].initialized) c.VK_IMAGE_LAYOUT_GENERAL else c.VK_IMAGE_LAYOUT_UNDEFINED;
        target_barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
        target_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        target_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        target_barrier.image = converter.targets[slot].image;
        target_barrier.subresourceRange = acquire.subresourceRange;

        const entry_barriers = [_]c.VkImageMemoryBarrier{ acquire, target_barrier };
        c.vkCmdPipelineBarrier(command, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, entry_barriers.len, &entry_barriers);

        c.vkCmdBindPipeline(command, c.VK_PIPELINE_BIND_POINT_COMPUTE, converter.pipeline);
        c.vkCmdBindDescriptorSets(command, c.VK_PIPELINE_BIND_POINT_COMPUTE, converter.pipeline_layout, 0, 1, &converter.sets[slot], 0, null);
        c.vkCmdDispatch(command, (width + 7) / 8, (height + 7) / 8, 1);

        // Release the camera buffer back to the foreign family so the
        // camera can reuse it.
        var release = acquire;
        release.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        release.dstAccessMask = 0;
        release.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        release.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        release.srcQueueFamilyIndex = converter.ctx.family;
        release.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT;
        c.vkCmdPipelineBarrier(command, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, &release);

        converter.targets[slot].initialized = true;
        try check(c.vkEndCommandBuffer(command));
    }
};
