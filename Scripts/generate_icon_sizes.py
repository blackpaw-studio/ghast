#!/usr/bin/env python3

import os
from PIL import Image

def generate_icon_sizes(base_path):
    """Generate all required macOS icon sizes from the base 1024x1024 image."""
    
    # Open the base image
    base_img = Image.open(base_path).convert("RGBA")
    
    # Icon sizes for macOS
    sizes = [
        (16, 1), (16, 2),      # 16x16 @1x and @2x
        (32, 1), (32, 2),      # 32x32 @1x and @2x
        (128, 1), (128, 2),    # 128x128 @1x and @2x
        (256, 1), (256, 2),    # 256x256 @1x and @2x
        (512, 1), (512, 2),    # 512x512 @1x and @2x
    ]
    
    base_dir = os.path.dirname(base_path)
    
    for base_size, scale in sizes:
        actual_size = base_size * scale
        
        if scale == 1:
            filename = f"icon_{base_size}x{base_size}.png"
        else:
            filename = f"icon_{base_size}x{base_size}@{scale}x.png"
        
        output_path = os.path.join(base_dir, filename)
        
        # Resize the image with high quality
        resized = base_img.resize((actual_size, actual_size), Image.Resampling.LANCZOS)
        
        # Save the result
        resized.save(output_path, 'PNG')
        print(f"Created icon: {output_path} ({actual_size}x{actual_size})")

if __name__ == "__main__":
    base_path = "/Users/evan/Developer/Github/ghast/Ghast/Assets.xcassets/AppIcon.appiconset/final_ghost_icon.png"
    generate_icon_sizes(base_path)
    print("\nAll icon sizes generated successfully!")