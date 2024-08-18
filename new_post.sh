#!/bin/bash

# Check if a title is provided
if [ -z "$1" ]; then
  echo "Usage: $0 'Post Title'"
  exit 1
fi

# Store the title and date
title="$1"
date=$(date '+%Y-%m-%d')

# Convert title to lowercase and replace spaces with hyphens
filename="_posts/${date}-$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-').md"

# Check if the file already exists
if [ -f "$filename" ]; then
  echo "Error: ${filename} already exists!"
  exit 1
fi

# Create the new post file with the default front matter
cat <<EOL > "$filename"
---
layout: post
title: $title
date: ${date}T00:00:00Z
categories: []
tags: []
---
EOL

# Output the filename
echo "New post created: $filename"
