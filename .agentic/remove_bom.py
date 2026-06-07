import os
import sys

def remove_bom(filepath):
    with open(filepath, 'rb') as f:
        data = f.read()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
        with open(filepath, 'wb') as f:
            f.write(data)
        return True
    return False

def main():
    target_dir = sys.argv[1] if len(sys.argv) > 1 else 'bin/multi_mode'
    count = 0
    for root, dirs, files in os.walk(target_dir):
        for file in files:
            if file.endswith('.py'):
                path = os.path.join(root, file)
                if remove_bom(path):
                    print(f'Removed BOM from {path}')
                    count += 1
    print(f'Total files fixed: {count}')

if __name__ == '__main__':
    main()
