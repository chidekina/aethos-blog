// Strip MDX module statements through a terminal semicolon/quote or blank line.
// Preserve fenced examples and prose immediately after terminated statements.
export function stripMdxStatements(body: string): string {
  let fence = '';
  let statement = false;
  return body.split('\n').filter((line) => {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (fence) {
      if (marker && marker[1][0] === fence[0]
          && marker[1].length >= fence.length && line.trim() === marker[1]) fence = '';
      return true;
    }
    if (statement) {
      if (!line.trim()) {
        statement = false;
        return true;
      }
      statement = !/[;'"]\s*$/.test(line);
      return false;
    }
    if (marker) fence = marker[1];
    if (!fence && /^(?:import|export)\s/.test(line)) {
      statement = !/[;'"]\s*$/.test(line);
      return false;
    }
    return true;
  }).join('\n');
}

