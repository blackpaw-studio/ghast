#!/usr/bin/env python3

import os
import sys
from PIL import Image, ImageDraw
import math

def create_rounded_icon(input_path, output_path, size):
    """Create a macOS-style rounded icon with proper corner radius and padding."""
    
    # Open the original image
    img = Image.open(input_path).convert("RGBA")
    
    # Add padding - macOS icons typically have about 10% padding
    padding_percent = 0.10
    padding = int(size * padding_percent)
    content_size = size - (padding * 2)
    
    # Resize the content to fit within the padded area
    if img.size != (content_size, content_size):
        img = img.resize((content_size, content_size), Image.Resampling.LANCZOS)
    
    # Create a new image with transparency for the full size
    rounded = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    
    # Create a mask for rounded corners
    # macOS uses a superellipse (squircle) with a specific curve
    # We'll approximate with a rounded rectangle
    # Corner radius is approximately 22.5% of the icon size for macOS
    corner_radius = int(size * 0.225)
    
    # Create a mask
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    
    # Draw a rounded rectangle
    draw.rounded_rectangle(
        [(0, 0), (size - 1, size - 1)],
        radius=corner_radius,
        fill=255
    )
    
    # Create a temporary image to hold the padded content
    temp = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    # Paste the resized image in the center with padding
    temp.paste(img, (padding, padding), img)
    
    # Apply the mask to the temp image
    temp.putalpha(mask)
    
    # Now paste to the final image, preserving transparency
    rounded = temp
    
    # Save the result
    rounded.save(output_path, 'PNG')
    print(f"Created rounded icon with padding: {output_path}")

def main():
    # Icon sizes for macOS
    sizes = [
        (16, 1), (16, 2),      # 16x16 @1x and @2x
        (32, 1), (32, 2),      # 32x32 @1x and @2x
        (128, 1), (128, 2),    # 128x128 @1x and @2x
        (256, 1), (256, 2),    # 256x256 @1x and @2x
        (512, 1), (512, 2),    # 512x512 @1x and @2x
    ]
    
    base_dir = "/Users/evan/Developer/Github/ghast/Ghast/Assets.xcassets/AppIcon.appiconset"
    
    for base_size, scale in sizes:
        actual_size = base_size * scale
        
        if scale == 1:
            filename = f"icon_{base_size}x{base_size}.png"
        else:
            filename = f"icon_{base_size}x{base_size}@{scale}x.png"
        
        input_path = os.path.join(base_dir, filename)
        output_path = input_path  # Overwrite the original
        
        if os.path.exists(input_path):
            create_rounded_icon(input_path, output_path, actual_size)
        else:
            print(f"Warning: {input_path} not found")

if __name__ == "__main__":
    main()