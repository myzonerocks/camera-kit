//! Decides whether this device runs the Vulkan backend. The requirements
//! are the ones zero-copy camera import rests on: the ycbcr sampler
//! conversion feature and the android hardware buffer memory extension, on
//! an actual GPU. A software rasterizer fails the probe by design: it can
//! never hold a camera budget, so it takes the declared GL fallback.

const std = @import("std");

const c = @cImport({
    @cDefine("VK_USE_PLATFORM_ANDROID_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

pub fn vulkanReady() bool {
    var app_info: c.VkApplicationInfo = std.mem.zeroes(c.VkApplicationInfo);
    app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.apiVersion = c.VK_API_VERSION_1_1;

    var instance_info: c.VkInstanceCreateInfo = std.mem.zeroes(c.VkInstanceCreateInfo);
    instance_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_info.pApplicationInfo = &app_info;

    var instance: c.VkInstance = null;
    if (c.vkCreateInstance(&instance_info, null, &instance) != c.VK_SUCCESS) return false;
    defer c.vkDestroyInstance(instance, null);

    var device_count: u32 = 0;
    if (c.vkEnumeratePhysicalDevices(instance, &device_count, null) != c.VK_SUCCESS or device_count == 0) return false;
    var devices: [8]c.VkPhysicalDevice = undefined;
    device_count = @min(device_count, devices.len);
    if (c.vkEnumeratePhysicalDevices(instance, &device_count, &devices) != c.VK_SUCCESS) return false;

    for (devices[0..device_count]) |device| {
        if (deviceReady(device)) return true;
    }
    return false;
}

fn deviceReady(device: c.VkPhysicalDevice) bool {
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(device, &properties);
    if (properties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_CPU) return false;
    if (properties.apiVersion < c.VK_API_VERSION_1_1) return false;

    var ycbcr: c.VkPhysicalDeviceSamplerYcbcrConversionFeatures = std.mem.zeroes(c.VkPhysicalDeviceSamplerYcbcrConversionFeatures);
    ycbcr.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    var features: c.VkPhysicalDeviceFeatures2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
    features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features.pNext = &ycbcr;
    c.vkGetPhysicalDeviceFeatures2(device, &features);
    if (ycbcr.samplerYcbcrConversion == c.VK_FALSE) return false;

    // One bounded pass keeps the probe allocation-free; no android driver
    // approaches this many device extensions.
    var extensions: [512]c.VkExtensionProperties = undefined;
    var count: u32 = extensions.len;
    const result = c.vkEnumerateDeviceExtensionProperties(device, null, &count, &extensions);
    if (result != c.VK_SUCCESS and result != c.VK_INCOMPLETE) return false;
    for (extensions[0..count]) |extension| {
        const name = std.mem.sliceTo(&extension.extensionName, 0);
        if (std.mem.eql(u8, name, "VK_ANDROID_external_memory_android_hardware_buffer")) {
            return true;
        }
    }
    return false;
}
